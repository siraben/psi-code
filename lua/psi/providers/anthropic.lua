-- psi.anthropic: agent turn loop + one-shot completions.
--
-- Entry points:
--   M.run_turn(opts) — streaming tool-dispatch loop; drives an
--       assistant turn given the current session state. Returns
--       (ok, final_text_or_error).
--   M.complete_text(opts) — non-streaming one-shot completion used
--       for background jobs like compaction summarization.
--
-- Caller supplies:
--   opts.system_prompt     string
--   opts.model             string or nil (falls back to env / default)
--   opts.max_tokens        integer
--   opts.tool_specs        array of tool-spec alists (filtered API shape)
--   opts.observer          table with optional callbacks; see
--                          agent.h struct psi_agent_observer
--   opts.abort_check       function() -> bool (true means abort)
--   opts.user_text         string (for complete_text only)
--
-- Session transcript is read and written via psi.session_* primitives.

local context = require("psi.context")
local prelude = require("psi.prelude")
local provider_loop = require("psi.provider_loop")
local sched = require("psi.sched")
local stream_parser = require("psi.stream_parser")
local transform = require("psi.transform_messages")
local image_policy = require("psi.image_policy")
local tools = require("psi.tools")
local session_mod = require("psi.session_manager")
local notice = require("psi.notice")
local auth_storage = require("psi.auth_storage")

local M = {}

-- A "flavour" bundles the provider-specific bits (endpoint, auth scheme, model
-- defaults, record labels) so the wire machinery below can be reused by any
-- API-compatible provider.
local ANTHROPIC_FLAVOR = {
  provider_name = "anthropic",
  api_name = "anthropic-messages",
  label = "Anthropic",
  api_key_envs = { "ANTHROPIC_API_KEY" },
  key_missing_msg = "ANTHROPIC_API_KEY is not set",
  model_env = "PSI_ANTHROPIC_MODEL",
  model_default = "claude-opus-4-8",
  base_url_env = "PSI_ANTHROPIC_BASE_URL",
  base_url_default = "https://api.anthropic.com/",
  auth_header = function(api_key)
    return "x-api-key: " .. api_key
  end,
  extra_headers = nil,
  allow_bridge = true,
}
M.ANTHROPIC_FLAVOR = ANTHROPIC_FLAVOR

local function api_url(flavor)
  local base = os.getenv(flavor.base_url_env) or flavor.base_url_default
  if base == "" then
    base = flavor.base_url_default
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. "v1/messages"
end

local function build_headers(flavor, api_key)
  local hdrs = {
    "content-type: application/json",
    "anthropic-version: 2023-06-01",
    flavor.auth_header(api_key),
  }
  if type(flavor.extra_headers) == "table" then
    for _, h in ipairs(flavor.extra_headers) do
      hdrs[#hdrs + 1] = h
    end
  end
  return hdrs
end

local function resolve_api_key(flavor)
  -- Match pi's precedence: auth.json first, then provider-specific env vars.
  local key = auth_storage.resolve_api_key(flavor.provider_name, nil)
  if key and key ~= "" then
    return key
  end
  for _, name in ipairs(flavor.api_key_envs) do
    local env_key = os.getenv(name)
    if env_key and env_key ~= "" then
      return env_key
    end
  end
  if flavor.allow_bridge and psi.amiga_bridge_api_key then
    local bridge = psi.amiga_bridge_api_key()
    if bridge and bridge ~= "" then
      return bridge
    end
  end
  return nil
end

local function resolve_model(flavor, m)
  return prelude.resolve_env(m, flavor.model_env, flavor.model_default)
end

local function has_api_key(flavor)
  -- Keep the route/auth gate side-effect free: do not resolve !commands here.
  if auth_storage.has_api_key_entry(flavor.provider_name) then
    return true
  end
  for _, name in ipairs(flavor.api_key_envs) do
    local key = os.getenv(name)
    if key and key ~= "" then
      return true
    end
  end
  if flavor.allow_bridge and psi.amiga_bridge_api_key then
    local bridge = psi.amiga_bridge_api_key()
    if bridge and bridge ~= "" then
      return true
    end
  end
  return false
end

-- Tool specs for the API: drop prompt_snippet + prompt_guidelines,
-- keep only name/description/input_schema.
local function api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      name = t.name,
      description = t.description,
      input_schema = t.input_schema,
    }
  end
  return out
end

-- ---------- Session -> API messages ----------

local safe_decode = prelude.safe_json_decode

-- Translate the v2 session data body into Anthropic's on-wire content
-- shape. pi's `toolCall` becomes Anthropic's `tool_use`; `toolResult`
-- becomes the `tool_result` user-message block.
--
-- Parity with pi's transform-messages.ts + anthropic.ts:
--   * text: strip ill-formed UTF-8 (Anthropic rejects any byte that
--     isn't a valid UTF-8 scalar value with HTTP 400 "surrogates not
--     allowed"); then skip the block entirely if it's empty-after-trim.
--   * toolCall → tool_use: verbatim id/name, input-object pass-through.
--   * thinking: re-emit with signature so interleaved-thinking stays
--     coherent if thinking is enabled; if the signature is missing
--     (older session or feature-off) fall back to a text block so the
--     reasoning content is not lost.
local function append_text_block(out, text)
  text = prelude.sanitize_surrogates(text or "")
  if prelude.trim(text) ~= "" then
    out[#out + 1] = { type = "text", text = text }
  end
end

local function pi_content_to_anthropic(blocks, images_enabled)
  if images_enabled == nil then
    images_enabled = true
  end
  local out = prelude.as_array({})
  for _, b in ipairs(blocks or {}) do
    if type(b) == "table" then
      if b.type == "text" then
        append_text_block(out, b.text)
      elseif b.type == "toolCall" then
        out[#out + 1] = { type = "tool_use", id = b.id, name = b.name, input = b.arguments or {} }
      elseif b.type == "image" and type(b.data) == "string" then
        if images_enabled then
          out[#out + 1] = {
            type = "image",
            source = {
              type = "base64",
              media_type = b.mimeType or "application/octet-stream",
              data = b.data,
            },
          }
        else
          append_text_block(out, image_policy.DISABLED_TEXT)
        end
      elseif b.type == "thinking" then
        if type(b.thinkingSignature) == "string" and b.thinkingSignature ~= "" then
          out[#out + 1] = {
            type = "thinking",
            thinking = b.thinking or "",
            signature = b.thinkingSignature,
          }
        else
          local t = prelude.sanitize_surrogates(b.thinking or "")
          if prelude.trim(t) ~= "" then
            out[#out + 1] = { type = "text", text = t }
          end
        end
      end
    end
  end
  return out
end

local function tool_result_content_blocks(content, images_enabled)
  if images_enabled == false and transform.has_images(content) then
    return transform.text_from_content_with_image_placeholder(content, image_policy.DISABLED_TEXT)
  end
  local has_images = transform.has_images(content)
  local parts = prelude.array(#(content or {}))
  if not has_images then
    if type(content) == "table" then
      for _, b in ipairs(content) do
        if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
          parts[#parts + 1] = b.text
        end
      end
    end
    return prelude.sanitize_surrogates(table.concat(parts, "\n"))
  end

  local out = prelude.as_array({})
  local has_text = false
  for _, b in ipairs(content or {}) do
    if type(b) == "table" then
      if b.type == "text" then
        local text = prelude.sanitize_surrogates(b.text or "")
        if prelude.trim(text) ~= "" then
          out[#out + 1] = { type = "text", text = text }
          has_text = true
        end
      elseif b.type == "image" and type(b.data) == "string" then
        out[#out + 1] = {
          type = "image",
          source = {
            type = "base64",
            media_type = b.mimeType or "application/octet-stream",
            data = b.data,
          },
        }
      end
    end
  end
  if not has_text then
    table.insert(out, 1, { type = "text", text = "(see attached image)" })
  end
  return out
end

local function tool_result_block(msg, images_enabled)
  -- pi stores toolResult.content as an array of content blocks; Anthropic
  -- accepts either a string or an array. Concatenate text blocks with
  -- "\n" (matches pi) and run the result through sanitize_surrogates,
  -- which strips any byte that isn't part of a valid UTF-8 scalar
  -- value so the on-wire body always validates.
  return {
    type = "tool_result",
    tool_use_id = msg.toolCallId or "",
    content = tool_result_content_blocks(msg.content, images_enabled),
    is_error = not not msg.isError,
  }
end

-- Build the Anthropic messages[] array from session entries.
--
-- Ported from pi-mono's transform-messages.ts:
--   * Assistant messages with stopReason "aborted" or "error" are skipped
--     entirely — their partial content should not be replayed.
--   * Orphan tool_use blocks (assistant with tool_use whose tool_result
--     never landed before the next user message) are resolved with a
--     synthetic tool_result containing "No result provided", isError=true,
--     inserted right before the next user message.
--   * Consecutive tool-result entries are coalesced into one user message.
local function build_api_messages(session, images_enabled)
  if images_enabled == nil then
    images_enabled = true
  end
  local out = prelude.array(#session)
  transform.replay_session(session, {
    user = function(message)
      out[#out + 1] = {
        role = "user",
        content = pi_content_to_anthropic(message.content, images_enabled),
      }
    end,
    assistant = function(message)
      local pending = prelude.array(#(message.content or {}))
      out[#out + 1] = {
        role = "assistant",
        content = pi_content_to_anthropic(message.content, images_enabled),
      }
      for _, block in ipairs(message.content or {}) do
        if type(block) == "table" and block.type == "toolCall" then
          pending[#pending + 1] = { id = block.id, name = block.name }
        end
      end
      return pending
    end,
    tool_result = function(message)
      local block = tool_result_block(message, images_enabled)
      return block.tool_use_id, block
    end,
    tool_results = function(blocks)
      out[#out + 1] = { role = "user", content = prelude.as_array(blocks) }
    end,
    synthetic_tool_results = function(calls)
      local blocks = prelude.array(#calls)
      for _, call in ipairs(calls) do
        blocks[#blocks + 1] = {
          type = "tool_result",
          tool_use_id = call.id,
          content = "No result provided",
          is_error = true,
        }
      end
      out[#out + 1] = { role = "user", content = prelude.as_array(blocks) }
    end,
    compaction_summary = function(summary)
      out[#out + 1] = { role = "user", content = summary }
    end,
    branch_summary = function(summary)
      out[#out + 1] = { role = "user", content = summary }
    end,
    custom_message = function(message)
      out[#out + 1] = {
        role = message.role == "assistant" and "assistant" or "user",
        content = pi_content_to_anthropic(message.content, images_enabled),
      }
    end,
  })
  return prelude.as_array(out)
end

-- ---------- Stream-state accumulator ----------

local function new_state()
  return {
    blocks = {}, -- 1-indexed, mirrors Anthropic's 0-based index+1
    stop_reason = nil,
    assistant_text_parts = {},
    usage = nil, -- merged usage object from message_start + message_delta
    response_id = nil, -- Anthropic server-side message id (from message_start)
  }
end

local function state_assistant_text(state)
  if state.assistant_text ~= nil then
    return state.assistant_text
  end
  state.assistant_text = table.concat(state.assistant_text_parts or {})
  return state.assistant_text
end

local function merge_usage(state, u)
  if type(u) ~= "table" then
    return
  end
  state.usage = state.usage or {}
  for _, k in ipairs({
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
  }) do
    if type(u[k]) == "number" then
      state.usage[k] = u[k]
    end
  end
end

local function on_message_start(state, data)
  local msg = data.message
  if type(msg) ~= "table" then
    return
  end
  merge_usage(state, msg.usage)
  if type(msg.id) == "string" then
    state.response_id = msg.id
  end
end

local function on_content_block_start(state, data)
  local idx = data.index
  if type(idx) ~= "number" then
    return
  end
  local cb = data.content_block or {}
  state.blocks[idx + 1] = {
    type = cb.type or "text",
    text_parts = cb.text and { cb.text } or {},
    id = cb.id,
    name = cb.name,
    input_json_parts = {},
    thinking_parts = cb.thinking and { cb.thinking } or {},
    signature_parts = cb.signature and { cb.signature } or {},
  }
end

local function on_content_block_delta(state, data, observer)
  local idx = data.index
  if type(idx) ~= "number" then
    return
  end
  local block = state.blocks[idx + 1]
  if not block then
    return
  end
  local d = data.delta or {}
  if d.type == "text_delta" and type(d.text) == "string" then
    block.text_parts[#block.text_parts + 1] = d.text
    state.assistant_text_parts[#state.assistant_text_parts + 1] = d.text
    state.assistant_text = nil
    if observer.on_assistant_text_delta then
      observer.on_assistant_text_delta(d.text)
    end
    if psi.events then
      psi.events.emit("assistant-text-delta", { text = d.text })
    end
  elseif d.type == "input_json_delta" and type(d.partial_json) == "string" then
    block.input_json_parts[#block.input_json_parts + 1] = d.partial_json
    if observer.on_tool_call_delta then
      observer.on_tool_call_delta(block.id, d.partial_json)
    end
    if psi.events then
      psi.events.emit("tool-call-delta", { id = block.id, partial_json = d.partial_json })
    end
  elseif d.type == "thinking_delta" and type(d.thinking) == "string" then
    block.thinking_parts[#block.thinking_parts + 1] = d.thinking
    if observer.on_thinking_delta then
      observer.on_thinking_delta(d.thinking)
    end
    if psi.events then
      psi.events.emit("thinking-delta", { text = d.thinking })
    end
  elseif d.type == "signature_delta" and type(d.signature) == "string" then
    -- Anthropic streams the thinking-block signature in one or more
    -- signature_delta events; concatenate for cross-turn replay.
    block.signature_parts[#block.signature_parts + 1] = d.signature
  end
end

local function on_message_delta(state, data)
  if type(data.delta) == "table" and type(data.delta.stop_reason) == "string" then
    state.stop_reason = data.delta.stop_reason
  end
  merge_usage(state, data.usage)
end

local function dispatch_sse(state, event_type, data, observer)
  if event_type == "content_block_start" then
    on_content_block_start(state, data)
  elseif event_type == "content_block_delta" then
    on_content_block_delta(state, data, observer)
  elseif event_type == "message_start" then
    on_message_start(state, data)
  elseif event_type == "message_delta" then
    on_message_delta(state, data)
  end
end

-- ---------- Content-block -> session encoding ----------

-- Returns (assistant_content_array_for_session, tool_use_blocks).
local function finalize_blocks(state)
  local content = prelude.as_array({})
  local tool_uses = {}
  -- state.blocks is a 1-indexed table but may be sparse if Anthropic
  -- skipped indices; iterate with pairs then sort by key.
  local keys = {}
  for k in pairs(state.blocks) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local block = state.blocks[k]
    if block.type == "text" then
      local text = table.concat(block.text_parts or {})
      content[#content + 1] = { type = "text", text = text }
    elseif block.type == "tool_use" then
      local input
      local input_json = table.concat(block.input_json_parts or {})
      if #input_json > 0 then
        input = safe_decode(input_json)
        if type(input) ~= "table" then
          -- Truncated/malformed input_json: surface via stream_error
          -- so the turn fails instead of dispatching with empty input.
          state.malformed_tool_input_error = state.malformed_tool_input_error
            or string.format(
              "tool_use %s (%s) has malformed input_json (%d bytes, starts with %q)",
              block.name or "?",
              block.id or "?",
              #input_json,
              input_json:sub(1, 48)
            )
          input = {}
        end
      else
        input = {}
      end
      content[#content + 1] = {
        type = "tool_use",
        id = block.id,
        name = block.name,
        input = input,
      }
      tool_uses[#tool_uses + 1] = {
        id = block.id,
        name = block.name,
        input = input,
        input_json = input_json,
      }
    elseif block.type == "thinking" then
      local thinking = table.concat(block.thinking_parts or {})
      local signature = table.concat(block.signature_parts or {})
      -- Preserve thinking blocks with the streamed signature so the
      -- session JSONL can round-trip through pi's transform-messages
      -- flow. Outgoing-request emission is decided at replay time
      -- (pi_content_to_anthropic) — if no signature survived, the
      -- content falls back to a text block there.
      content[#content + 1] = {
        type = "thinking",
        thinking = thinking,
        signature = signature,
      }
    end
  end
  return content, tool_uses
end

-- ---------- Abort / error bookkeeping ----------
--
-- Matches pi's shape: the partial assistant is persisted as-is (no
-- trimming, no synthesis). Request-build time filters these entries out
-- (see build_api_messages). Orphan tool_use blocks are resolved at
-- request-build time with synthetic "No result provided" tool_results,
-- so we deliberately do NOT emit synthetic results here.
--
-- stop_reason: "aborted" (signal abort) | "error" (network / non-2xx)
local function save_failed_partial(flavor, state, model, stop_reason, error_message)
  if not state then
    return
  end
  local assistant_text = state_assistant_text(state)
  local has_text = assistant_text ~= ""
  local has_blocks = next(state.blocks) ~= nil
  if not has_text and not has_blocks then
    return
  end
  local content = finalize_blocks(state)
  session_mod.append_assistant(assistant_text, content, {
    usage = state.usage,
    stop_reason = stop_reason,
    error_message = error_message,
    model = model,
    provider = flavor.provider_name,
    api = flavor.api_name,
    response_id = state.response_id,
  })
  context.record_usage(psi.session_message_count(), state.usage, model)
  session_mod.save()
end

-- ---------- Prompt caching helpers ----------
--
-- Anthropic's ephemeral prompt cache lets subsequent requests in the same
-- session skip re-encoding large prefixes. pi's pattern (ported here):
--   * system prompt: array of text blocks; the last gets cache_control
--   * tools: last tool in the array gets cache_control (caches whole list)
--   * messages: last block of the *final* message gets cache_control
-- Together these create cache breakpoints that persist for ~5 min.

local CACHE_ENV = "PSI_PROMPT_CACHE"

local function caching_enabled()
  local v = os.getenv(CACHE_ENV)
  return v ~= "0" and v ~= "false"
end

local EPHEMERAL = { type = "ephemeral" }

local function system_as_blocks(system_prompt)
  if type(system_prompt) == "table" then
    return system_prompt
  end
  -- Anthropic rejects any request body that isn't well-formed UTF-8
  -- with HTTP 400 "str is not valid UTF-8: surrogates not
  -- allowed". The system prompt is assembled from project-context files
  -- (AGENTS.md / CLAUDE.md) and tool descriptions, any of which may
  -- contain bytes the model later echoes back. Match pi-mono's
  -- anthropic.ts which sanitizes the system prompt as well.
  local text = prelude.sanitize_surrogates(system_prompt or "")
  local block = { type = "text", text = text }
  if caching_enabled() and text ~= "" then
    block.cache_control = EPHEMERAL
  end
  return prelude.as_array({ block })
end

local function tools_with_cache(tool_specs)
  if not caching_enabled() then
    return tool_specs
  end
  local out = prelude.array(#tool_specs)
  local n = #tool_specs
  for i, t in ipairs(tool_specs) do
    local copy = {}
    for k, v in pairs(t) do
      copy[k] = v
    end
    if i == n then
      copy.cache_control = EPHEMERAL
    end
    out[#out + 1] = copy
  end
  return out
end

-- Tag the last block of the last message with cache_control. Anthropic
-- accepts cache_control on text, image, tool_use, and tool_result blocks.
local function mark_last_message_cache(messages)
  if not caching_enabled() or #messages == 0 then
    return messages
  end
  local last = messages[#messages]
  if type(last.content) == "string" then
    last.content = prelude.as_array({
      { type = "text", text = last.content, cache_control = EPHEMERAL },
    })
    return messages
  end
  if type(last.content) == "table" and #last.content > 0 then
    local blocks = last.content
    local tail = blocks[#blocks]
    if type(tail) == "table" then
      -- Shallow-copy to avoid mutating session-derived tables.
      local copy = {}
      for k, v in pairs(tail) do
        copy[k] = v
      end
      copy.cache_control = EPHEMERAL
      blocks[#blocks] = copy
    end
  end
  return messages
end

-- ---------- Auto-compaction (threshold check on usage) ----------

local AUTO_COMPACT_ENV = "PSI_AUTO_COMPACT"

local function auto_compact_enabled()
  local v = os.getenv(AUTO_COMPACT_ENV)
  return v ~= "0" and v ~= "false"
end

local function maybe_auto_compact(model, opts)
  if opts and opts.no_auto_compact then
    return
  end
  if not auto_compact_enabled() then
    return
  end
  local over, est = context.should_compact(model)
  if not over then
    return
  end
  notice.info(
    string.format(
      "psi: auto-compacting (context ~%d tokens, threshold %d)",
      est.tokens,
      context.context_window(model) - context.reserve_tokens()
    )
  )
  -- Lazy require to avoid a load-time cycle with psi.agent.
  local keep = context.keep_recent_messages(context.keep_recent_tokens())
  local ok, summary = require("psi.agent_session").run_compact({
    keep_recent = keep,
    model = model,
  })
  if not ok then
    notice.error("psi: auto-compaction failed")
  else
    context.reset_usage()
    session_mod.save()
    if summary and summary ~= "" then
      notice.info("psi: compacted; kept " .. tostring(keep) .. " recent messages")
    end
  end
end

M.maybe_auto_compact = maybe_auto_compact

-- ---------- One-shot completion (non-streaming) ----------

local http_post_text = sched.http_post_text

function M.complete_text(opts, flavor)
  flavor = flavor or ANTHROPIC_FLAVOR
  local api_key = resolve_api_key(flavor)
  if not api_key then
    notice.error(flavor.key_missing_msg)
    return false, flavor.key_missing_msg
  end
  -- Same UTF-8 sanitisation as the streaming path; both fields arrive
  -- on the wire as JSON strings and Anthropic refuses any malformed
  -- UTF-8 anywhere in the body.
  local request = {
    model = resolve_model(flavor, opts.model),
    max_tokens = opts.max_tokens or 2048,
    system = prelude.sanitize_surrogates(opts.system_prompt or ""),
    messages = prelude.as_array({
      { role = "user", content = prelude.sanitize_surrogates(opts.user_text or "") },
    }),
    stream = false,
  }
  local status, body = http_post_text(
    api_url(flavor),
    build_headers(flavor, api_key),
    psi.json_encode(request),
    opts.abort_check
  )
  if status == nil then
    notice.error("http post failed: " .. tostring(body))
    return false
  end
  if status < 200 or status >= 300 then
    notice.error(
      flavor.label .. " API request failed (" .. tostring(status) .. "): " .. (body or "")
    )
    return false
  end
  local parsed = safe_decode(body)
  if not parsed or type(parsed.content) ~= "table" then
    return false
  end
  local text_parts = {}
  for _, block in ipairs(parsed.content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      text_parts[#text_parts + 1] = block.text
    end
  end
  return true, table.concat(text_parts)
end

function M.has_auth(flavor)
  return has_api_key(flavor or ANTHROPIC_FLAVOR)
end

-- ---------- Agent turn (streaming + tool loop) ----------

function M.run_turn(opts, flavor)
  flavor = flavor or ANTHROPIC_FLAVOR
  local api_key = resolve_api_key(flavor)
  if not api_key then
    notice.error(flavor.key_missing_msg)
    return false, flavor.key_missing_msg
  end

  local model = resolve_model(flavor, opts.model)
  local max_tokens = opts.max_tokens or 16384
  return provider_loop.run_turn({
    model = model,
    max_tokens = max_tokens,
    system_prompt = opts.system_prompt or "",
    tool_specs = opts.tool_specs,
    observer = opts.observer,
    abort_check = opts.abort_check,
    no_auto_compact = opts.no_auto_compact,
  }, {
    provider_name = flavor.provider_name,
    api_name = flavor.api_name,
    url = api_url(flavor),
    headers = build_headers(flavor, api_key),
    tool_specs = api_tool_specs,
    build_messages = function(session)
      return build_api_messages(session, not image_policy.blocked())
    end,
    request_body = function(args)
      return {
        model = args.model,
        max_tokens = args.max_tokens,
        system = system_as_blocks(args.system_prompt or ""),
        messages = mark_last_message_cache(args.messages),
        tools = tools_with_cache(args.tool_specs),
        stream = true,
      }
    end,
    new_state = new_state,
    parser_new = stream_parser.sse_parser,
    parser_push = function(parser, chunk, state, observer)
      stream_parser.push_sse(parser, chunk, {
        multi_data = true,
        on_event = function(event_type, data)
          local parsed = safe_decode(data)
          if parsed then
            dispatch_sse(state, event_type, parsed, observer)
          end
        end,
      })
    end,
    finalize = finalize_blocks,
    stream_error = function(state)
      if state.malformed_tool_input_error then
        return flavor.provider_name .. ": " .. state.malformed_tool_input_error
      end
      return nil
    end,
    persist = function(state, persisted_model, content, _tool_uses, stop_override, error_message)
      session_mod.append_assistant(state_assistant_text(state), content, {
        usage = state.usage,
        stop_reason = stop_override or state.stop_reason,
        error_message = error_message,
        model = persisted_model,
        provider = flavor.provider_name,
        api = flavor.api_name,
        response_id = state.response_id,
      })
    end,
    response_id = function(state)
      return state.response_id
    end,
    save_failed_partial = function(state, partial_model, reason, emsg)
      save_failed_partial(flavor, state, partial_model, reason, emsg)
    end,
    classify_http_error = require("psi.providers.openai_compat").classify_http_error,
    text = state_assistant_text,
    after_iteration = function(iter_model, iter_opts)
      maybe_auto_compact(iter_model, iter_opts)
    end,
  })
end

-- Exported for tests/bench.py only. Safe to drop if internal.
M._test = {
  new_sse_parser = stream_parser.sse_parser,
  sse_push = function(parser, chunk, on_event)
    stream_parser.push_sse(parser, chunk, {
      multi_data = true,
      on_event = function(event_type, data)
        local parsed = safe_decode(data)
        if parsed then
          on_event(event_type, parsed)
        end
      end,
    })
  end,
  new_state = new_state,
  dispatch_sse = dispatch_sse,
  finalize_blocks = finalize_blocks,
  state_assistant_text = state_assistant_text,
  build_api_messages = build_api_messages,
  system_as_blocks = system_as_blocks,
  pi_content_to_anthropic = pi_content_to_anthropic,
  tool_result_block = tool_result_block,
}

return M
