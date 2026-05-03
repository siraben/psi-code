-- psi.openai_codex: OpenAI Codex provider via ChatGPT backend
-- `POST /backend-api/codex/responses`.

local auth = require("psi.providers.oauth_openai_codex")
local openai_compat = require("psi.providers.openai_compat")
local prelude = require("psi.prelude")
local provider_loop = require("psi.provider_loop")
local sched = require("psi.sched")
local settings = require("psi.settings_manager")
local session_mod = require("psi.session_manager")
local stream_parser = require("psi.stream_parser")
local thinking = require("psi.thinking")
local tools = require("psi.tools")
local transform = require("psi.transform_messages")

local M = {}

local BASE_URL_ENV = "PSI_OPENAI_CODEX_BASE_URL"
local BASE_URL_DEFAULT = "https://chatgpt.com/backend-api"
local MODEL_ENV = "PSI_OPENAI_CODEX_MODEL"
local MODEL_DEFAULT = "gpt-5.5"

local function base_url()
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  return (base:gsub("/+$", ""))
end

local function api_url()
  local base = base_url()
  if base:match("/codex/responses$") then
    return base
  end
  if base:match("/codex$") then
    return base .. "/responses"
  end
  return base .. "/codex/responses"
end

local function resolve_model(m)
  return prelude.resolve_env(m, MODEL_ENV, MODEL_DEFAULT)
end

local function headers(creds)
  return {
    "Authorization: Bearer " .. creds.access,
    "chatgpt-account-id: " .. creds.accountId,
    "originator: psi",
    "User-Agent: psi",
    "OpenAI-Beta: responses=experimental",
    "accept: text/event-stream",
    "content-type: application/json",
  }
end

local function api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      type = "function",
      name = t.name,
      description = t.description,
      parameters = t.input_schema,
    }
  end
  return out
end

local safe_decode = prelude.safe_json_decode

local function text_signature(id, phase)
  local sig = { v = 1, id = id }
  if phase then
    sig.phase = phase
  end
  return psi.json_encode(sig)
end

local function split_tool_id(id)
  local call_id, item_id = tostring(id or ""):match("^([^|]+)|(.+)$")
  if call_id then
    return call_id, item_id
  end
  return tostring(id or ""), nil
end

local function response_input_from_session(session, _system_prompt)
  local out = prelude.array(#session)
  local msg_index = 0

  local function user_input(text)
    return {
      role = "user",
      content = prelude.as_array({
        { type = "input_text", text = text or "" },
      }),
    }
  end

  local function assistant_text(text)
    local entry = {
      type = "message",
      role = "assistant",
      status = "completed",
      id = "msg_" .. tostring(msg_index),
      content = prelude.as_array({
        {
          type = "output_text",
          text = text or "",
          annotations = prelude.as_array({}),
        },
      }),
    }
    msg_index = msg_index + 1
    return entry
  end

  local function tool_output(call_id, output)
    return {
      type = "function_call_output",
      call_id = call_id,
      output = output or "",
    }
  end

  transform.replay_session(session, {
    user = function(message)
      out[#out + 1] = user_input(transform.text_from_content(message.content))
    end,
    assistant = function(message)
      local pending = prelude.array(#(message.content or {}))
      for _, block in ipairs(message.content or {}) do
        if type(block) == "table" and block.type == "thinking" then
          local item = safe_decode(block.thinkingSignature)
          if type(item) == "table" then
            out[#out + 1] = item
          end
        elseif type(block) == "table" and block.type == "text" then
          out[#out + 1] = assistant_text(block.text or "")
        elseif type(block) == "table" and block.type == "toolCall" then
          local call_id, item_id = split_tool_id(block.id)
          if call_id ~= "" then
            pending[#pending + 1] = { id = call_id, name = block.name }
            out[#out + 1] = {
              type = "function_call",
              id = item_id,
              call_id = call_id,
              name = block.name,
              arguments = psi.json_encode(block.arguments or {}),
            }
          end
        end
      end
      return pending
    end,
    tool_result = function(message)
      local call_id = split_tool_id(message.toolCallId)
      return call_id, tool_output(call_id, transform.tool_result_text(message))
    end,
    tool_results = function(messages)
      for _, message in ipairs(messages) do
        out[#out + 1] = message
      end
    end,
    synthetic_tool_results = function(calls)
      for _, call in ipairs(calls) do
        out[#out + 1] = tool_output(call.id, "No result provided")
      end
    end,
    compaction_summary = function(summary)
      out[#out + 1] = user_input(summary)
    end,
    custom_message = function(message)
      local text = transform.text_from_content(message.content)
      if message.role == "assistant" then
        out[#out + 1] = assistant_text(text)
      else
        out[#out + 1] = user_input(text)
      end
    end,
  })
  return out
end

local function request_body(args)
  local body = {
    model = args.model,
    store = false,
    stream = true,
    instructions = args.system_prompt or "",
    input = args.messages,
    text = { verbosity = os.getenv("PSI_OPENAI_CODEX_VERBOSITY") or "low" },
    include = prelude.as_array({ "reasoning.encrypted_content" }),
    tool_choice = "auto",
    parallel_tool_calls = true,
  }
  local effort = args.thinking_level
  if effort == nil or effort == "" then
    effort = args.reasoning_effort
  end
  if effort == nil or effort == "" then
    effort = os.getenv("PSI_OPENAI_CODEX_REASONING")
  end
  if effort == nil or effort == "" then
    effort = settings.get("defaults.reasoning_effort", nil)
  end
  if effort == nil or effort == "" then
    effort = thinking.DEFAULT
  end
  if effort == "none" then
    effort = "off"
  end
  local request_effort = thinking.request_effort(effort, { id = args.model, reasoning = true })
  if request_effort then
    body.reasoning = { effort = request_effort, summary = "auto" }
  end
  if args.tool_specs and #args.tool_specs > 0 then
    body.tools = args.tool_specs
  end
  return body
end

local function new_state()
  return {
    blocks = {},
    current = nil,
    usage = nil,
    stop_reason = nil,
    response_id = nil,
    error_message = nil,
  }
end

local function block_text(block)
  return table.concat(block.text_parts or {})
end

local function parse_args(text)
  local parsed = safe_decode(text or "{}", nil)
  return type(parsed) == "table" and parsed or {}
end

local function finish_item(state, item)
  local current = state.current
  if type(item) ~= "table" then
    state.current = nil
    return
  end
  if item.type == "message" and current and current.kind == "text" then
    if type(item.content) == "table" then
      local parts = {}
      for _, p in ipairs(item.content) do
        if type(p) == "table" then
          parts[#parts + 1] = p.text or p.refusal or ""
        end
      end
      current.text_parts = { table.concat(parts) }
    end
    current.id = item.id or current.id
    current.phase = item.phase
  elseif item.type == "reasoning" and current and current.kind == "thinking" then
    if type(item.summary) == "table" then
      local parts = {}
      for _, p in ipairs(item.summary) do
        if type(p) == "table" and type(p.text) == "string" then
          parts[#parts + 1] = p.text
        end
      end
      current.text_parts = { table.concat(parts, "\n\n") }
    end
    current.signature = psi.json_encode(item)
  elseif item.type == "function_call" and current and current.kind == "tool" then
    current.arg_text = item.arguments or current.arg_text or ""
    current.arguments = parse_args(current.arg_text)
  end
  state.current = nil
end

local function map_status(status)
  if status == "incomplete" then
    return "length"
  end
  if status == "failed" or status == "cancelled" then
    return "error"
  end
  return "stop"
end

local function handle_event(data, state, observer)
  if data == "[DONE]" then
    return
  end
  local event = safe_decode(data)
  if type(event) ~= "table" then
    return
  end
  local typ = event.type
  if typ == "error" then
    state.stop_reason = "error"
    state.error_message = "Codex error: " .. tostring(event.message or event.code or data)
    state.current = nil
  elseif typ == "response.failed" then
    local err = type(event.response) == "table" and event.response.error or nil
    state.stop_reason = "error"
    state.error_message = "Codex response failed: "
      .. tostring(type(err) == "table" and err.message or data)
    state.current = nil
  elseif typ == "response.created" and type(event.response) == "table" then
    state.response_id = event.response.id
  elseif typ == "response.output_item.added" and type(event.item) == "table" then
    local item = event.item
    if item.type == "message" then
      local b = { kind = "text", text_parts = {}, id = item.id }
      state.blocks[#state.blocks + 1] = b
      state.current = b
    elseif item.type == "reasoning" then
      local b = { kind = "thinking", text_parts = {} }
      state.blocks[#state.blocks + 1] = b
      state.current = b
    elseif item.type == "function_call" then
      local b = {
        kind = "tool",
        id = tostring(item.call_id or "") .. "|" .. tostring(item.id or ""),
        name = item.name,
        arg_text = item.arguments or "",
        arguments = parse_args(item.arguments or "{}"),
      }
      state.blocks[#state.blocks + 1] = b
      state.current = b
    end
  elseif typ == "response.reasoning_summary_text.delta" then
    if state.current and state.current.kind == "thinking" then
      local delta = event.delta or ""
      state.current.text_parts[#state.current.text_parts + 1] = delta
      if observer.on_thinking_delta then
        observer.on_thinking_delta(delta)
      end
    end
  elseif typ == "response.reasoning_summary_part.done" then
    if state.current and state.current.kind == "thinking" then
      state.current.text_parts[#state.current.text_parts + 1] = "\n\n"
      if observer.on_thinking_delta then
        observer.on_thinking_delta("\n\n")
      end
    end
  elseif typ == "response.output_text.delta" or typ == "response.refusal.delta" then
    if state.current and state.current.kind == "text" then
      local delta = event.delta or ""
      state.current.text_parts[#state.current.text_parts + 1] = delta
      if observer.on_assistant_text_delta then
        observer.on_assistant_text_delta(delta)
      end
    end
  elseif typ == "response.function_call_arguments.delta" then
    if state.current and state.current.kind == "tool" then
      state.current.arg_text = (state.current.arg_text or "") .. (event.delta or "")
      state.current.arguments = parse_args(state.current.arg_text)
    end
  elseif typ == "response.function_call_arguments.done" then
    if state.current and state.current.kind == "tool" then
      state.current.arg_text = event.arguments or state.current.arg_text or ""
      state.current.arguments = parse_args(state.current.arg_text)
    end
  elseif typ == "response.output_item.done" then
    finish_item(state, event.item)
  elseif
    (typ == "response.completed" or typ == "response.done" or typ == "response.incomplete")
    and type(event.response) == "table"
  then
    local r = event.response
    state.response_id = r.id or state.response_id
    state.stop_reason = map_status(r.status)
    if type(r.usage) == "table" then
      local cached = 0
      if type(r.usage.input_tokens_details) == "table" then
        cached = tonumber(r.usage.input_tokens_details.cached_tokens) or 0
      end
      state.usage = {
        input_tokens = math.max(0, (tonumber(r.usage.input_tokens) or 0) - cached),
        output_tokens = tonumber(r.usage.output_tokens) or 0,
        cache_read_input_tokens = cached,
        cache_creation_input_tokens = 0,
      }
    end
  end
end

local function parser_push(parser, chunk, state, observer)
  stream_parser.push_sse(parser, chunk, {
    multi_data = true,
    on_event = function(_, data)
      handle_event(data, state, observer)
    end,
  })
end

local function finalize(state)
  local tool_calls = prelude.array(#state.blocks)
  for _, b in ipairs(state.blocks) do
    if b.kind == "tool" and b.name and b.name ~= "" then
      -- Malformed arg_text → stream_error; don't dispatch with {}.
      local raw = b.arg_text or ""
      local args = b.arguments
      if not args and #raw > 0 then
        local parsed = safe_decode(raw, nil)
        if type(parsed) ~= "table" then
          state.malformed_tool_input_error = state.malformed_tool_input_error
            or string.format(
              "tool call %s (%s) has malformed arguments (%d bytes, starts with %q)",
              b.name or "?",
              b.id or "?",
              #raw,
              raw:sub(1, 48)
            )
          parsed = {}
        end
        args = parsed
      end
      tool_calls[#tool_calls + 1] = {
        id = b.id,
        name = b.name,
        arguments = args or {},
      }
    end
  end
  if #tool_calls > 0 and (state.stop_reason == nil or state.stop_reason == "stop") then
    state.stop_reason = "tool_use"
  end
  return nil, tool_calls
end

local function state_text(state)
  local out = prelude.array(#(state.blocks or {}))
  for _, b in ipairs(state.blocks or {}) do
    if b.kind == "text" then
      out[#out + 1] = block_text(b)
    end
  end
  return table.concat(out)
end

local function persist(state, model, _content, tool_calls, stop_override, error_message)
  local blocks = prelude.array(#(state.blocks or {}))
  for _, b in ipairs(state.blocks or {}) do
    if b.kind == "thinking" then
      blocks[#blocks + 1] = {
        type = "thinking",
        thinking = block_text(b),
        signature = b.signature,
      }
    elseif b.kind == "text" then
      blocks[#blocks + 1] = {
        type = "text",
        text = block_text(b),
        textSignature = text_signature(b.id, b.phase),
      }
    elseif b.kind == "tool" then
      blocks[#blocks + 1] = {
        type = "tool_use",
        id = b.id,
        name = b.name,
        input = b.arguments or parse_args(b.arg_text or "{}"),
      }
    end
  end
  session_mod.append_assistant(state_text(state), blocks, {
    usage = state.usage,
    stop_reason = stop_override or state.stop_reason,
    error_message = error_message or state.error_message,
    model = model,
    provider = "openai-codex",
    api = "openai-codex-responses",
    response_id = state.response_id,
  })
  if #tool_calls > 0 then
    state.stop_reason = "tool_use"
  end
end

local http_post_text = sched.http_post_text

function M.run_turn(opts)
  local creds, err = auth.credentials()
  if not creds then
    io.stderr:write(
      "openai-codex auth failed: " .. tostring(err) .. "\nRun /login openai-codex first.\n"
    )
    return false, err
  end
  local model = resolve_model(opts.model)
  return provider_loop.run_turn({
    model = model,
    max_tokens = opts.max_tokens,
    thinking_level = opts.thinking_level,
    reasoning_effort = opts.reasoning_effort,
    system_prompt = opts.system_prompt or "",
    tool_specs = opts.tool_specs,
    observer = opts.observer,
    abort_check = opts.abort_check,
    no_auto_compact = opts.no_auto_compact,
  }, {
    provider_name = "openai-codex",
    api_name = "openai-codex-responses",
    url = api_url(),
    headers = headers(creds),
    tool_specs = api_tool_specs,
    build_messages = function(session, system_prompt)
      return response_input_from_session(session, system_prompt)
    end,
    request_body = request_body,
    parser_new = stream_parser.sse_parser,
    parser_push = parser_push,
    new_state = new_state,
    finalize = finalize,
    persist = persist,
    classify_http_error = openai_compat.classify_http_error,
    stream_error = function(state)
      if state.stop_reason == "error" then
        return state.error_message or "Codex response failed"
      end
      if state.malformed_tool_input_error then
        return "openai-codex: " .. state.malformed_tool_input_error
      end
      return nil
    end,
    text = state_text,
    has_partial = function(state, tool_calls)
      return state_text(state) ~= "" or #tool_calls > 0
    end,
    after_iteration = function(turn_model, turn_opts)
      local ok, anthropic = pcall(require, "psi.providers.anthropic")
      if ok and anthropic and anthropic.maybe_auto_compact then
        anthropic.maybe_auto_compact(turn_model, turn_opts)
      end
    end,
  })
end

function M.complete_text(opts)
  local creds, err = auth.credentials()
  if not creds then
    io.stderr:write("openai-codex auth failed: " .. tostring(err) .. "\n")
    return false
  end
  local model = resolve_model(opts.model)
  local body = request_body({
    model = model,
    system_prompt = opts.system_prompt or "",
    messages = prelude.as_array({
      {
        role = "user",
        content = prelude.as_array({ { type = "input_text", text = opts.user_text or "" } }),
      },
    }),
    tool_specs = prelude.as_array({}),
    max_tokens = opts.max_tokens,
    thinking_level = opts.thinking_level,
    reasoning_effort = opts.reasoning_effort,
  })
  body.stream = false
  body.tools = nil
  local status, response =
    http_post_text(api_url(), headers(creds), psi.json_encode(body), opts.abort_check)
  if not status or status < 200 or status >= 300 then
    io.stderr:write(
      "openai-codex request failed: " .. tostring(status) .. " " .. tostring(response) .. "\n"
    )
    return false
  end
  local parsed = safe_decode(response)
  local parts = {}
  local output = type(parsed) == "table" and parsed.output or nil
  if type(output) == "table" then
    for _, item in ipairs(output) do
      if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
        for _, c in ipairs(item.content) do
          if type(c) == "table" then
            parts[#parts + 1] = c.text or c.refusal or ""
          end
        end
      end
    end
  end
  return true, table.concat(parts)
end

M._debug = {
  response_input_from_session = response_input_from_session,
  request_body = request_body,
  handle_event = handle_event,
  new_state = new_state,
  parser_new = stream_parser.sse_parser,
  parser_push = parser_push,
  finalize = finalize,
  classify_http_error = openai_compat.classify_http_error,
}

return M
