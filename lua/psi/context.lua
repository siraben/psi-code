-- psi.context: dynamic context-window accounting.
--
-- Ported from pi-mono's compaction.ts token-budget machinery:
--   - estimate_tokens(text): char/4 heuristic
--   - record_usage(idx, usage): remember the last API-reported totals
--   - estimate_context_tokens(): usage-measured base + heuristic tail
--   - should_compact(model): base+tail > window - reserve
--   - compaction_budget() / turn_prefix_budget(): 0.8 / 0.5 * reserve
--
-- Uses psi.api_registry model metadata when available, with a conservative
-- fallback for unknown/custom models. Runtime callers should pass either a
-- resolved descriptor or both the bare model id and provider name.

local M = {}

local MODEL_CONTEXT_WINDOWS = {
  ["claude-opus-4-8"] = 1000000,
  ["claude-opus-4-7"] = 1000000,
  ["claude-opus-4-6"] = 1000000,
  ["claude-opus-4-5"] = 200000,
  ["claude-sonnet-4-6"] = 1000000,
  ["claude-sonnet-4-5"] = 200000,
  ["claude-haiku-4-5"] = 200000,
}
local DEFAULT_CONTEXT_WINDOW = 128000
local DEFAULT_RESERVE_TOKENS = 16384
local DEFAULT_KEEP_RECENT_TOKENS = 20000

-- Last successful API usage. Shape: {message_index=N, total=T}.
-- `message_index` is the session index of the assistant reply whose response
-- produced these numbers; everything at index > N is estimated.
local last_usage = nil

function M.estimate_tokens(text)
  if not text or #text == 0 then
    return 0
  end
  return math.ceil(#text / 4)
end

function M.reset_usage()
  last_usage = nil
  -- Zero the C-side mirror too; the TUI status line reads from it
  -- without touching Lua so it must be kept in sync.
  if psi.set_usage then
    psi.set_usage(0, 0, 0, 0, 0, 0)
  end
end

function M.last_usage()
  return last_usage
end

-- `usage` is the Anthropic usage object; fields may be nil/absent.
-- `model` is optional; passed through so the C-side usage mirror can
-- also remember the context-window limit for display.
local function compaction_setting(name, default)
  local ok, settings = pcall(require, "psi.settings_manager")
  local value = ok and settings and settings.get("compaction." .. name, nil) or nil
  value = tonumber(value)
  if value == nil or value < 0 then
    return default
  end
  return math.floor(value)
end

function M.record_usage(message_index, usage, model, provider)
  if type(usage) ~= "table" or type(message_index) ~= "number" then
    return
  end
  local input = usage.input_tokens or 0
  local output = usage.output_tokens or 0
  local cr = usage.cache_read_input_tokens or 0
  local cw = usage.cache_creation_input_tokens or 0
  local total = input + output + cr + cw
  last_usage = {
    message_index = message_index,
    total = total,
    input = input,
    output = output,
    cache_read = cr,
    cache_write = cw,
  }
  if psi.set_usage then
    psi.set_usage(input, output, cr, cw, total, M.context_window(model, provider))
  end
end

-- Estimate total tokens currently in context:
--   usage_tokens  — measured from last API response
--   trailing      — char/4 estimate for messages appended after that point
function M.estimate_context_tokens()
  local base_index = (last_usage and last_usage.message_index) or 0
  local base_total = (last_usage and last_usage.total) or 0
  local count = psi.session_message_count()
  local trailing = 0
  if psi.session_token_estimate_from then
    trailing = psi.session_token_estimate_from(base_total == 0 and 1 or (base_index + 1))
  else
    local messages = base_total == 0 and psi.session_messages()
      or psi.session_messages_from(base_index + 1)
    for i = 1, #messages do
      local m = messages[i]
      trailing = trailing + M.estimate_tokens(m.text)
      if m.data then
        trailing = trailing + M.estimate_tokens(m.data)
      end
    end
  end
  -- With no measured baseline, `messages` is the whole transcript.
  return {
    tokens = base_total + trailing,
    usage_tokens = base_total,
    trailing_tokens = trailing,
    last_usage_index = base_index,
    message_count = count,
  }
end

function M.context_window(model, provider)
  if type(model) == "table" then
    if type(model.context_window) == "number" then
      return model.context_window
    end
    provider = model.provider or provider
    model = model.id or model.model or model.ref
  end
  if not model or model == "" then
    return DEFAULT_CONTEXT_WINDOW
  end
  local ok, providers = pcall(require, "psi.api_registry")
  if ok and providers then
    local canonical = provider and provider ~= "" and (provider .. "/" .. model) or model
    local meta = providers.model(canonical) or providers.model(model)
    if type(meta) == "table" and type(meta.context_window) == "number" then
      return meta.context_window
    end
  end
  return MODEL_CONTEXT_WINDOWS[model] or DEFAULT_CONTEXT_WINDOW
end

function M.reserve_tokens()
  return compaction_setting("reserveTokens", DEFAULT_RESERVE_TOKENS)
end
function M.keep_recent_tokens()
  return compaction_setting("keepRecentTokens", DEFAULT_KEEP_RECENT_TOKENS)
end

function M.auto_compact_enabled()
  local env = os.getenv("PSI_AUTO_COMPACT")
  if env == "0" or env == "false" then
    return false
  elseif env == "1" or env == "true" then
    return true
  end
  local ok, settings = pcall(require, "psi.settings_manager")
  if ok and settings then
    return settings.get("compaction.enabled", true) ~= false
  end
  return true
end

function M.should_compact(model, provider)
  if not M.auto_compact_enabled() then
    return false, M.estimate_context_tokens()
  end
  local est = M.estimate_context_tokens()
  local threshold = M.context_window(model, provider) - M.reserve_tokens()
  return est.tokens > threshold, est
end

-- Output-token budgets for summarization calls (mirrors pi's 0.8 / 0.5).
function M.compaction_budget()
  return math.floor(0.8 * M.reserve_tokens())
end
function M.turn_prefix_budget()
  return math.floor(0.5 * M.reserve_tokens())
end

-- Walk the session from the tail, accumulating estimated tokens; return the
-- number of most-recent messages that fit within `target_tokens`. Used to
-- translate pi's keepRecentTokens knob into the message-count that psi's
-- compaction API expects.
function M.keep_recent_messages(target_tokens)
  target_tokens = target_tokens or DEFAULT_KEEP_RECENT_TOKENS
  if psi.session_keep_recent_by_tokens then
    return psi.session_keep_recent_by_tokens(target_tokens)
  end
  local messages = psi.session_messages()
  local total, count = 0, 0
  for i = #messages, 1, -1 do
    local m = messages[i]
    local t = M.estimate_tokens(m.text)
    if m.data then
      t = t + M.estimate_tokens(m.data)
    end
    if count > 0 and total + t > target_tokens then
      break
    end
    total = total + t
    count = count + 1
  end
  return count
end

local OVERFLOW_PATTERNS = {
  "prompt is too long",
  "request_too_large",
  "input is too long for requested model",
  "exceeds the context window",
  "maximum context length",
  "input token count",
  "maximum prompt length",
  "reduce the length of the messages",
  "maximum allowed input length",
  "longer than the model's context length",
  "exceeds the available context size",
  "greater than the context length",
  "context window exceeds limit",
  "exceeded model token limit",
  "too large for model with",
  "configured context size",
  "model_context_window_exceeded",
  "prompt too long",
  "range of input length should be",
  "context_length_exceeded",
  "context length exceeded",
  "too many tokens",
  "token limit exceeded",
}

local NON_OVERFLOW_PATTERNS = {
  "rate limit",
  "too many requests",
  "throttling error",
  "service unavailable",
}

function M.is_overflow_error(message)
  if type(message) ~= "string" or message == "" then
    return false
  end
  local lower = message:lower()
  for _, pattern in ipairs(NON_OVERFLOW_PATTERNS) do
    if lower:find(pattern, 1, true) then
      return false
    end
  end
  for _, pattern in ipairs(OVERFLOW_PATTERNS) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return lower:match("^400%s+status code%s+%(no body%)") ~= nil
    or lower:match("^413%s+status code%s+%(no body%)") ~= nil
end

function M.usage_exceeds_window(model, provider)
  if not last_usage then
    return false
  end
  local input = (last_usage.input or 0) + (last_usage.cache_read or 0)
  return input > M.context_window(model, provider)
end

return M
