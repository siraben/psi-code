-- psi.codex: OpenAI Responses API provider (the wire api the Codex
-- CLI speaks).
--
-- Talks `POST /v1/responses` with SSE streaming. Distinct from
-- chat/completions: input is a typed item list (messages,
-- function_call, function_call_output) instead of a roles-and-text
-- list, and tool calls arrive as their own output items rather than
-- being nested in an assistant message.
--
-- Default model is `gpt-5.1-codex` (the model the Codex CLI ships
-- with). To use this provider:
--
--     psi --model=codex/gpt-5.1-codex --agent="..."
--     PSI_PROVIDER=codex psi --agent="..."
--
-- Auth (in priority order):
--   1. $OPENAI_API_KEY
--   2. $CODEX_API_KEY (alias)
--   3. ~/.codex/auth.json access_token (codex CLI's ChatGPT login)
--
-- Env knobs:
--   PSI_CODEX_MODEL              default model
--   PSI_CODEX_BASE_URL           override https://api.openai.com
--   PSI_CODEX_REASONING_EFFORT   minimal | low | medium | high
--   PSI_CODEX_REASONING_SUMMARY  auto | concise | detailed | none
--
-- Compared to anthropic.lua / openai_compat.lua:
--   * Provides its own SSE event mapping (Responses-API specific).
--   * Persists assistant text + thinking + toolCall blocks in the
--     same v2 session shape, so on-disk transcripts stay
--     provider-neutral. Sessions started under codex can be resumed
--     under anthropic/openrouter modulo provider-specific flags.

local context = require("psi.context")
local prelude = require("psi.prelude")
local provider_loop = require("psi.provider_loop")
local transform = require("psi.message_transform")
local tools = require("psi.tools")
local session_mod = require("psi.session")

local M = {}

local MODEL_ENV = "PSI_CODEX_MODEL"
local MODEL_DEFAULT = "gpt-5.1-codex"
local BASE_URL_ENV = "PSI_CODEX_BASE_URL"
local BASE_URL_DEFAULT = "https://api.openai.com/"
local REASONING_EFFORT_ENV = "PSI_CODEX_REASONING_EFFORT"
local REASONING_SUMMARY_ENV = "PSI_CODEX_REASONING_SUMMARY"

local safe_decode = prelude.safe_json_decode

-- ---------- URL + headers + auth ----------

local function api_url()
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  if base == "" then
    base = BASE_URL_DEFAULT
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. "v1/responses"
end

-- Read the codex CLI's ChatGPT-OAuth access token as a fallback when
-- $OPENAI_API_KEY is unset. Format (~/.codex/auth.json):
--   { "OPENAI_API_KEY": "...", "tokens": { "access_token": "..." } }
local function read_codex_auth()
  local home = os.getenv("HOME")
  if not home or home == "" then
    return nil
  end
  local path = home .. "/.codex/auth.json"
  if psi.file_exists and not psi.file_exists(path) then
    return nil
  end
  local ok, body = pcall(psi.read_file, path)
  if not ok or type(body) ~= "string" or body == "" then
    return nil
  end
  local parsed = safe_decode(body)
  if type(parsed) ~= "table" then
    return nil
  end
  if type(parsed.OPENAI_API_KEY) == "string" and parsed.OPENAI_API_KEY ~= "" then
    return parsed.OPENAI_API_KEY, "api_key"
  end
  if type(parsed.tokens) == "table" then
    local access = parsed.tokens.access_token
    if type(access) == "string" and access ~= "" then
      return access, "chatgpt"
    end
  end
  return nil
end

-- Returns (token, kind) where kind is "api_key" or "chatgpt".
-- kind controls which header naming the Responses endpoint expects.
local function resolve_auth()
  local key = os.getenv("OPENAI_API_KEY")
  if key and key ~= "" then
    return key, "api_key"
  end
  key = os.getenv("CODEX_API_KEY")
  if key and key ~= "" then
    return key, "api_key"
  end
  return read_codex_auth()
end

local function codex_headers(token, kind)
  local hdrs = {
    "content-type: application/json",
    "Authorization: Bearer " .. token,
  }
  if kind == "chatgpt" then
    -- The Responses API hosted on chatgpt.com expects an
    -- originator + chatgpt-account-id; api.openai.com ignores them.
    hdrs[#hdrs + 1] = "OpenAI-Beta: responses=v1"
    hdrs[#hdrs + 1] = "originator: codex_cli_rs"
  end
  return hdrs
end

local function resolve_model(m)
  if m and m ~= "" then
    return m
  end
  local env = os.getenv(MODEL_ENV)
  if env and env ~= "" then
    return env
  end
  return MODEL_DEFAULT
end

-- ---------- Tool specs (Responses-API shape) ----------
--
-- Responses tools are flat:
--   { type = "function", name, description, parameters, strict = false }
-- (chat/completions wraps the same fields under .function.)
local function api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      type = "function",
      name = t.name,
      description = t.description,
      parameters = t.input_schema,
      strict = false,
    }
  end
  return out
end

-- ---------- Session -> Responses input items ----------
--
-- Input shape per turn (chronological, no coalescing):
--   { type="message", role="user"|"assistant", content=[
--       { type="input_text", text=...} | { type="output_text", text=... }
--     ] }
--   { type="function_call", call_id, name, arguments }   -- assistant tool call
--   { type="function_call_output", call_id, output }      -- tool result (string)
--
-- Mirrors anthropic.lua's build_api_messages defences:
--   * Skip aborted/error assistants.
--   * Drop orphan tool_results (their tool_call was compacted away).
--   * Synthesize "No result provided" stubs for tool_calls that never
--     received a result before the next user turn.
local function build_api_input(session)
  local out = prelude.as_array({})
  local pending_tool_calls = {}
  local seen_result_ids = {}
  local known_tool_use_ids = {}

  local function flush_synthetic_results()
    for _, tc in ipairs(pending_tool_calls) do
      if not seen_result_ids[tc.id] then
        out[#out + 1] = {
          type = "function_call_output",
          call_id = tc.id,
          output = "No result provided",
        }
      end
    end
    pending_tool_calls = {}
    seen_result_ids = {}
  end

  local function user_message(content_blocks)
    local content = prelude.as_array({})
    if type(content_blocks) == "string" then
      if content_blocks ~= "" then
        content[#content + 1] = { type = "input_text", text = content_blocks }
      end
    elseif type(content_blocks) == "table" then
      for _, b in ipairs(content_blocks) do
        if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
          local t = prelude.sanitize_surrogates(b.text)
          if prelude.trim(t) ~= "" then
            content[#content + 1] = { type = "input_text", text = t }
          end
        end
      end
    end
    if #content == 0 then
      return nil
    end
    return { type = "message", role = "user", content = content }
  end

  local i, n = 1, #session
  while i <= n do
    local m = session[i]
    local message, body = transform.message_body(m)
    local role = m.role

    if role == "user" and message then
      flush_synthetic_results()
      local item = user_message(message.content)
      if item then
        out[#out + 1] = item
      end
      i = i + 1
    elseif role == "assistant" and message then
      if transform.skip_assistant(message) then
        i = i + 1
      else
        flush_synthetic_results()
        local content = prelude.as_array({})
        local emitted_tool_calls = {}
        for _, b in ipairs(message.content or {}) do
          if type(b) == "table" then
            if b.type == "text" and type(b.text) == "string" then
              local t = prelude.sanitize_surrogates(b.text)
              if prelude.trim(t) ~= "" then
                content[#content + 1] = { type = "output_text", text = t }
              end
            elseif b.type == "toolCall" then
              emitted_tool_calls[#emitted_tool_calls + 1] = b
            end
            -- thinking blocks are not replayed (Responses
            -- reasoning items are tied to a server-side response_id
            -- and cannot be reused cross-request).
          end
        end
        if #content > 0 then
          out[#out + 1] = { type = "message", role = "assistant", content = content }
        end
        for _, b in ipairs(emitted_tool_calls) do
          out[#out + 1] = {
            type = "function_call",
            call_id = b.id,
            name = b.name,
            arguments = psi.json_encode(b.arguments or {}),
          }
          if b.id ~= nil and b.id ~= "" then
            known_tool_use_ids[b.id] = true
          end
        end

        pending_tool_calls = {}
        seen_result_ids = {}
        for _, b in ipairs(emitted_tool_calls) do
          pending_tool_calls[#pending_tool_calls + 1] = { id = b.id, name = b.name }
        end
        i = i + 1
      end
    elseif role == "tool-result" then
      while i <= n and session[i].role == "tool-result" do
        local b = safe_decode(session[i].data)
        if type(b) == "table" and type(b.message) == "table" then
          local tm = b.message
          local text = transform.tool_result_text(tm)
          local tid = tm.toolCallId or ""
          if tid ~= "" and known_tool_use_ids[tid] then
            out[#out + 1] = {
              type = "function_call_output",
              call_id = tid,
              output = prelude.sanitize_surrogates(text or ""),
            }
            seen_result_ids[tid] = true
          end
        end
        i = i + 1
      end
    elseif role == "compaction-summary" then
      flush_synthetic_results()
      local summary = (type(body) == "table" and body.summary) or m.text or ""
      if summary ~= "" then
        out[#out + 1] = {
          type = "message",
          role = "user",
          content = prelude.as_array({
            { type = "input_text", text = summary },
          }),
        }
      end
      i = i + 1
    elseif
      role == "custom"
      and type(body) == "table"
      and body.__entry_type == "custom_message"
      and type(body.message) == "table"
      and not body.message.hidden
    then
      flush_synthetic_results()
      local cm = body.message
      if cm.role == "assistant" then
        local content = prelude.as_array({})
        if type(cm.content) == "table" then
          for _, b in ipairs(cm.content) do
            if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
              content[#content + 1] = { type = "output_text", text = b.text }
            end
          end
        end
        if #content > 0 then
          out[#out + 1] = { type = "message", role = "assistant", content = content }
        end
      else
        local item = user_message(cm.content)
        if item then
          out[#out + 1] = item
        end
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  flush_synthetic_results()
  return out
end

-- ---------- SSE parser (event + data, two-line records) ----------
--
-- Event names we care about:
--   response.created                — has .response.id
--   response.output_text.delta      — { delta = "..." }
--   response.reasoning_summary_text.delta — { delta = "..." }
--   response.reasoning_text.delta   — { delta = "..." }   (older builds)
--   response.output_item.added      — { item = { type="function_call",
--                                       id, call_id, name, arguments } }
--                                  or { item = { type="reasoning", id } }
--   response.function_call_arguments.delta — { item_id, delta }
--   response.function_call_arguments.done  — { item_id, arguments }
--   response.completed              — { response = { id, usage, status } }
--   response.failed                 — { response = { error = {...} } }
--   response.error                  — top-level transport error
--
-- All other events (output_item.done variants, content_part.added,
-- in_progress, etc.) are ignored: we already accumulate from the
-- delta + done pair. Mirrors codex CLI's stream_events_utils path.

local function new_sse_parser()
  return { line = {}, pending_event = nil, pending_data = {} }
end

local function sse_dispatch_line(parser, line, on_event)
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if line:sub(1, 7) == "event: " then
    parser.pending_event = line:sub(8)
  elseif line:sub(1, 6) == "data: " then
    -- SSE allows multiple `data:` lines per event; concatenated with
    -- "\n". Responses API only ever sends one but we handle both.
    parser.pending_data[#parser.pending_data + 1] = line:sub(7)
  elseif line == "" then
    if parser.pending_event and #parser.pending_data > 0 then
      local raw = table.concat(parser.pending_data, "\n")
      local data = safe_decode(raw)
      if data ~= nil then
        on_event(parser.pending_event, data)
      end
    end
    parser.pending_event = nil
    parser.pending_data = {}
  end
end

local function sse_push(parser, chunk, on_event)
  local start = 1
  local len = #chunk
  while start <= len do
    local nl = chunk:find("\n", start, true)
    if not nl then
      parser.line[#parser.line + 1] = chunk:sub(start)
      break
    end
    parser.line[#parser.line + 1] = chunk:sub(start, nl - 1)
    local line = table.concat(parser.line)
    parser.line = {}
    sse_dispatch_line(parser, line, on_event)
    start = nl + 1
  end
end

-- ---------- Stream-state accumulator ----------

local function new_state()
  return {
    text_parts = {},
    thinking_parts = {},
    -- Two flavours of reasoning stream: terse summary and full
    -- chain-of-thought. Concatenated separately so we can persist a
    -- single thinking block without interleaving them mid-token.
    reasoning_summary_parts = {},
    -- function_call items keyed by their server-side item id; we
    -- concatenate argument deltas into arg_parts.
    items = {}, -- [item_id] = { id, call_id, name, arg_parts = {} }
    tool_calls_order = {}, -- emission order (item_id list)
    usage = nil,
    stop_reason = nil,
    response_id = nil,
    error = nil,
  }
end

local function state_text(state)
  if type(state.text) == "string" then
    return state.text
  end
  state.text = table.concat(state.text_parts or {})
  return state.text
end

local function state_thinking(state)
  if type(state.thinking) == "string" then
    return state.thinking
  end
  local summary = table.concat(state.reasoning_summary_parts or {})
  local detail = table.concat(state.thinking_parts or {})
  if summary ~= "" and detail ~= "" then
    state.thinking = summary .. "\n\n" .. detail
  elseif summary ~= "" then
    state.thinking = summary
  else
    state.thinking = detail
  end
  return state.thinking
end

local function ensure_item(state, item_id, defaults)
  local slot = state.items[item_id]
  if slot then
    if defaults then
      if defaults.call_id and (not slot.call_id or slot.call_id == "") then
        slot.call_id = defaults.call_id
      end
      if defaults.name and (not slot.name or slot.name == "") then
        slot.name = defaults.name
      end
    end
    return slot
  end
  slot = {
    id = item_id,
    call_id = defaults and defaults.call_id or nil,
    name = defaults and defaults.name or nil,
    arg_parts = {},
  }
  state.items[item_id] = slot
  state.tool_calls_order[#state.tool_calls_order + 1] = item_id
  return slot
end

-- ---------- Event dispatch ----------

local function on_response_created(state, data)
  local resp = data.response
  if type(resp) == "table" and type(resp.id) == "string" then
    state.response_id = resp.id
  end
end

local function on_text_delta(state, data, observer)
  local text = data.delta
  if type(text) ~= "string" or text == "" then
    return
  end
  state.text_parts[#state.text_parts + 1] = text
  state.text = nil
  if observer.on_assistant_text_delta then
    observer.on_assistant_text_delta(text)
  end
  if psi.events then
    psi.events.emit("assistant-text-delta", { text = text })
  end
end

local function on_reasoning_summary_delta(state, data, observer)
  local text = data.delta
  if type(text) ~= "string" or text == "" then
    return
  end
  state.reasoning_summary_parts[#state.reasoning_summary_parts + 1] = text
  state.thinking = nil
  if observer.on_thinking_delta then
    observer.on_thinking_delta(text)
  end
  if psi.events then
    psi.events.emit("thinking-delta", { text = text })
  end
end

local function on_reasoning_text_delta(state, data, observer)
  local text = data.delta
  if type(text) ~= "string" or text == "" then
    return
  end
  state.thinking_parts[#state.thinking_parts + 1] = text
  state.thinking = nil
  if observer.on_thinking_delta then
    observer.on_thinking_delta(text)
  end
  if psi.events then
    psi.events.emit("thinking-delta", { text = text })
  end
end

local function on_output_item_added(state, data)
  local item = data.item
  if type(item) ~= "table" then
    return
  end
  if item.type == "function_call" then
    -- Responses delivers .id (the item id, used to match
    -- function_call_arguments.delta) AND .call_id (stable id used
    -- in subsequent function_call_output items). We persist call_id
    -- as the session-side tool_use id so cross-turn replay works.
    local item_id = item.id
    if type(item_id) == "string" and item_id ~= "" then
      ensure_item(state, item_id, {
        call_id = item.call_id,
        name = item.name,
      })
      -- If arguments arrived inline (no streaming), capture them.
      if type(item.arguments) == "string" and item.arguments ~= "" then
        local slot = state.items[item_id]
        slot.arg_parts[#slot.arg_parts + 1] = item.arguments
      end
    end
  end
  -- reasoning items are accumulated via reasoning_*_text.delta; no
  -- per-item bookkeeping needed.
end

local function on_function_call_args_delta(state, data, observer)
  local item_id = data.item_id
  if type(item_id) ~= "string" or item_id == "" then
    return
  end
  local slot = ensure_item(state, item_id, nil)
  local d = data.delta
  if type(d) == "string" and d ~= "" then
    slot.arg_parts[#slot.arg_parts + 1] = d
    if observer.on_tool_call_delta then
      observer.on_tool_call_delta(slot.call_id or item_id, d)
    end
    if psi.events then
      psi.events.emit("tool-call-delta", {
        id = slot.call_id or item_id,
        partial_json = d,
      })
    end
  end
end

local function on_function_call_args_done(state, data)
  local item_id = data.item_id
  if type(item_id) ~= "string" or item_id == "" then
    return
  end
  local slot = ensure_item(state, item_id, nil)
  -- Some servers send the full assembled arguments here in addition
  -- to the deltas. Prefer the assembled string when our concat'd
  -- deltas are empty (catches the no-streaming inline case).
  if type(data.arguments) == "string" and #slot.arg_parts == 0 then
    slot.arg_parts[#slot.arg_parts + 1] = data.arguments
  end
end

-- usage shape on Responses:
--   { input_tokens, output_tokens, total_tokens,
--     input_tokens_details = { cached_tokens },
--     output_tokens_details = { reasoning_tokens } }
local function merge_usage(state, u)
  if type(u) ~= "table" then
    return
  end
  state.usage = state.usage or {}
  state.usage.output_tokens = u.output_tokens or state.usage.output_tokens or 0
  local input = u.input_tokens or state.usage.input_tokens or 0
  local cached = 0
  if type(u.input_tokens_details) == "table" then
    cached = tonumber(u.input_tokens_details.cached_tokens) or 0
  end
  state.usage.cache_read = cached
  -- Match the openai_compat normalization: report input as
  -- non-cached input_tokens so the context tracker doesn't
  -- double-count cache hits.
  state.usage.input_tokens = math.max(0, input - cached)
  if type(u.output_tokens_details) == "table" then
    local rt = tonumber(u.output_tokens_details.reasoning_tokens) or 0
    if rt > 0 then
      state.usage.reasoning_tokens = rt
    end
  end
end

local function on_completed(state, data)
  local resp = data.response
  if type(resp) ~= "table" then
    return
  end
  if type(resp.id) == "string" then
    state.response_id = resp.id
  end
  if type(resp.status) == "string" then
    state.stop_reason = resp.status -- usually "completed"
  end
  merge_usage(state, resp.usage)
end

local function on_failed(state, data)
  state.stop_reason = "error"
  local resp = data.response
  if type(resp) == "table" and type(resp.error) == "table" then
    local err = resp.error
    state.error = err.message or err.code or err.type or "request failed"
  end
end

local function dispatch_sse(state, event_type, data, observer)
  if event_type == "response.created" then
    on_response_created(state, data)
  elseif event_type == "response.output_text.delta" then
    on_text_delta(state, data, observer)
  elseif event_type == "response.reasoning_summary_text.delta" then
    on_reasoning_summary_delta(state, data, observer)
  elseif event_type == "response.reasoning_text.delta" then
    on_reasoning_text_delta(state, data, observer)
  elseif event_type == "response.output_item.added" then
    on_output_item_added(state, data)
  elseif event_type == "response.function_call_arguments.delta" then
    on_function_call_args_delta(state, data, observer)
  elseif event_type == "response.function_call_arguments.done" then
    on_function_call_args_done(state, data)
  elseif event_type == "response.completed" then
    on_completed(state, data)
  elseif event_type == "response.failed" or event_type == "response.error" then
    on_failed(state, data)
  end
end

-- ---------- Finalize ----------
--
-- Returns (assistant_session_content, tool_call_blocks). Tool calls
-- use call_id as the session-side tool_use id so subsequent turns'
-- function_call_output items round-trip correctly.
local function finalize(state)
  local content = prelude.as_array({})
  local tool_uses = {}
  local thinking = state_thinking(state)
  if thinking ~= "" then
    content[#content + 1] = { type = "thinking", thinking = thinking }
  end
  local text = state_text(state)
  if text ~= "" then
    content[#content + 1] = { type = "text", text = text }
  end
  for _, item_id in ipairs(state.tool_calls_order) do
    local slot = state.items[item_id]
    if slot and slot.name then
      local call_id = slot.call_id
      if not call_id or call_id == "" then
        call_id = "call_" .. prelude.uuid_short():sub(1, 12)
      end
      local arg_json = table.concat(slot.arg_parts)
      local args = nil
      if #arg_json > 0 then
        args = safe_decode(arg_json)
        if type(args) ~= "table" then
          io.stderr:write(
            string.format(
              "psi: codex tool_call %s (%s) has malformed arguments "
                .. "(%d bytes, starts with %q); dispatching with empty input\n",
              slot.name or "?",
              call_id or "?",
              #arg_json,
              arg_json:sub(1, 48)
            )
          )
          args = {}
        end
      else
        args = {}
      end
      content[#content + 1] = {
        type = "tool_use",
        id = call_id,
        name = slot.name,
        input = args,
      }
      tool_uses[#tool_uses + 1] = {
        id = call_id,
        name = slot.name,
        arguments = args,
      }
    end
  end
  return content, tool_uses
end

-- ---------- Failed / partial persistence ----------

local function save_failed_partial(state, model, stop_reason, error_message)
  if not state then
    return
  end
  local has_text = state_text(state) ~= ""
  local has_thinking = state_thinking(state) ~= ""
  local has_calls = next(state.items) ~= nil
  if not has_text and not has_thinking and not has_calls then
    return
  end
  local content = finalize(state)
  session_mod.append_assistant(state_text(state), content, {
    usage = state.usage,
    stop_reason = stop_reason,
    error_message = error_message or state.error,
    model = model,
    provider = "codex",
    api = "openai-responses",
    response_id = state.response_id,
  })
  context.record_usage(psi.session_message_count(), state.usage, model)
  session_mod.save()
end

-- ---------- HTTP error classification (delegates to openai_compat) ----------

local classify_http_error = require("psi.openai_compat").classify_http_error

-- ---------- Request body ----------

local function reasoning_block()
  local effort = os.getenv(REASONING_EFFORT_ENV)
  local summary = os.getenv(REASONING_SUMMARY_ENV)
  if (not effort or effort == "") and (not summary or summary == "") then
    return nil
  end
  local r = {}
  if effort and effort ~= "" then
    r.effort = effort
  end
  if summary and summary ~= "" and summary ~= "none" then
    r.summary = summary
  end
  return r
end

local function build_request_body(args)
  local body = {
    model = args.model,
    input = args.messages,
    instructions = args.system_prompt or "",
    tools = args.tool_specs,
    stream = true,
    store = false, -- don't accumulate state server-side; psi owns history
    parallel_tool_calls = true,
  }
  if args.max_tokens then
    body.max_output_tokens = args.max_tokens
  end
  local r = reasoning_block()
  if r then
    body.reasoning = r
  end
  return body
end

-- ---------- One-shot completion (compaction) ----------

function M.complete_text(opts)
  local token, kind = resolve_auth()
  if not token then
    io.stderr:write("OPENAI_API_KEY is not set\n")
    return false
  end
  local body = {
    model = resolve_model(opts.model),
    instructions = opts.system_prompt or "",
    input = prelude.as_array({
      {
        type = "message",
        role = "user",
        content = prelude.as_array({
          { type = "input_text", text = opts.user_text or "" },
        }),
      },
    }),
    stream = false,
    store = false,
    max_output_tokens = opts.max_tokens or 2048,
  }
  local r = reasoning_block()
  if r then
    body.reasoning = r
  end
  local status, response = psi.http_post(api_url(), codex_headers(token, kind), psi.json_encode(body))
  if status == nil then
    io.stderr:write("codex: http post failed: " .. tostring(response) .. "\n")
    return false
  end
  if status < 200 or status >= 300 then
    io.stderr:write(("codex: request failed (%d): %s\n"):format(status, response or ""))
    return false
  end
  local parsed = safe_decode(response)
  if type(parsed) ~= "table" then
    return false
  end
  -- Non-streaming Responses puts everything in .output (an array of
  -- items in the same shape as streamed output_item.added).
  local parts = {}
  if type(parsed.output) == "table" then
    for _, item in ipairs(parsed.output) do
      if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
        for _, c in ipairs(item.content) do
          if type(c) == "table" and c.type == "output_text" and type(c.text) == "string" then
            parts[#parts + 1] = c.text
          end
        end
      end
    end
  end
  return true, table.concat(parts)
end

-- ---------- Agent turn (streaming + tool loop) ----------

function M.run_turn(opts)
  local token, kind = resolve_auth()
  if not token then
    io.stderr:write("OPENAI_API_KEY is not set\n")
    return false
  end

  local model = resolve_model(opts.model)
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
    provider_name = "codex",
    api_name = "openai-responses",
    url = api_url(),
    headers = codex_headers(token, kind),
    tool_specs = api_tool_specs,
    build_messages = function(session)
      return build_api_input(session)
    end,
    request_body = build_request_body,
    new_state = new_state,
    parser_new = new_sse_parser,
    parser_push = function(parser, chunk, state, observer)
      sse_push(parser, chunk, function(event_type, data)
        dispatch_sse(state, event_type, data, observer)
      end)
    end,
    finalize = finalize,
    persist = function(state, persisted_model, content, _tool_uses, stop_override, error_message)
      session_mod.append_assistant(state_text(state), content, {
        usage = state.usage,
        stop_reason = stop_override or state.stop_reason,
        error_message = error_message or state.error,
        model = persisted_model,
        provider = "codex",
        api = "openai-responses",
        response_id = state.response_id,
      })
    end,
    has_partial = function(state, tool_calls)
      return state_text(state) ~= ""
        or state_thinking(state) ~= ""
        or #tool_calls > 0
    end,
    response_id = function(state)
      return state.response_id
    end,
    save_failed_partial = save_failed_partial,
    classify_http_error = classify_http_error,
    text = state_text,
    after_iteration = function() end,
  })
end

-- Exported for tests.
M._test = {
  new_sse_parser = new_sse_parser,
  sse_push = sse_push,
  new_state = new_state,
  dispatch_sse = dispatch_sse,
  finalize = finalize,
  build_api_input = build_api_input,
  state_text = state_text,
  state_thinking = state_thinking,
  resolve_model = resolve_model,
  api_tool_specs = api_tool_specs,
  reasoning_block = reasoning_block,
  build_request_body = build_request_body,
}

return M
