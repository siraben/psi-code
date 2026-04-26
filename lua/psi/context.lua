-- psi.context: dynamic context-window accounting.
--
-- Ported from pi-mono's compaction.ts token-budget machinery:
--   - estimate_tokens(text): char/4 heuristic
--   - record_usage(idx, usage): remember the last API-reported totals
--   - estimate_context_tokens(): usage-measured base + heuristic tail
--   - should_compact(model): base+tail > window - reserve
--   - compaction_budget() / turn_prefix_budget(): 0.8 / 0.5 * reserve
--
-- Uses psi.providers model metadata when available, with a conservative
-- fallback for unknown/custom models.

local M = {}

local MODEL_CONTEXT_WINDOWS = {
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
function M.record_usage(message_index, usage, model)
  if type(usage) ~= "table" or type(message_index) ~= "number" then
    return
  end
  local input = usage.input_tokens or 0
  local output = usage.output_tokens or 0
  local cr = usage.cache_read_input_tokens or 0
  local cw = usage.cache_creation_input_tokens or 0
  local total = input + output + cr + cw
  last_usage = { message_index = message_index, total = total }
  if psi.set_usage then
    psi.set_usage(input, output, cr, cw, total, M.context_window(model))
  end
end

-- Estimate total tokens currently in context:
--   usage_tokens  — measured from last API response
--   trailing      — char/4 estimate for messages appended after that point
function M.estimate_context_tokens()
  local messages = psi.session_messages()
  local base_index = (last_usage and last_usage.message_index) or 0
  local base_total = (last_usage and last_usage.total) or 0
  local trailing = 0
  for i = base_index + 1, #messages do
    local m = messages[i]
    trailing = trailing + M.estimate_tokens(m.text)
    if m.data then
      trailing = trailing + M.estimate_tokens(m.data)
    end
  end
  if base_total == 0 then
    -- No measured baseline yet: estimate the whole transcript.
    for i = 1, base_index do
      local m = messages[i]
      trailing = trailing + M.estimate_tokens(m.text)
      if m.data then
        trailing = trailing + M.estimate_tokens(m.data)
      end
    end
  end
  return {
    tokens = base_total + trailing,
    usage_tokens = base_total,
    trailing_tokens = trailing,
    last_usage_index = base_index,
    message_count = #messages,
  }
end

function M.context_window(model)
  if not model or model == "" then
    return DEFAULT_CONTEXT_WINDOW
  end
  local ok, providers = pcall(require, "psi.providers")
  if ok and providers then
    local meta = providers.model(model)
    if type(meta) == "table" and type(meta.context_window) == "number" then
      return meta.context_window
    end
  end
  return MODEL_CONTEXT_WINDOWS[model] or DEFAULT_CONTEXT_WINDOW
end

function M.reserve_tokens()
  return DEFAULT_RESERVE_TOKENS
end
function M.keep_recent_tokens()
  return DEFAULT_KEEP_RECENT_TOKENS
end

function M.should_compact(model)
  local est = M.estimate_context_tokens()
  local threshold = M.context_window(model) - DEFAULT_RESERVE_TOKENS
  return est.tokens > threshold, est
end

-- Output-token budgets for summarization calls (mirrors pi's 0.8 / 0.5).
function M.compaction_budget()
  return math.floor(0.8 * DEFAULT_RESERVE_TOKENS)
end
function M.turn_prefix_budget()
  return math.floor(0.5 * DEFAULT_RESERVE_TOKENS)
end

-- Walk the session from the tail, accumulating estimated tokens; return the
-- number of most-recent messages that fit within `target_tokens`. Used to
-- translate pi's keepRecentTokens knob into the message-count that psi's
-- compaction API expects.
function M.keep_recent_messages(target_tokens)
  target_tokens = target_tokens or DEFAULT_KEEP_RECENT_TOKENS
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

return M
