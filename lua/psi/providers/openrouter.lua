-- psi.openrouter: OpenRouter provider (OpenAI `chat/completions`
-- wire format). Thin adapter over psi.openai_compat; this file
-- supplies URL, auth + attribution headers, request body, the SSE
-- stream parser, and a delta handler that deals with OpenAI's
-- fragmented tool-call arguments + cached_tokens disambiguation.
--
-- Prefix the model with `openrouter/` (e.g.
-- `openrouter/google/gemini-3-flash-preview`) to route through this
-- provider. psi.agent.pick_provider strips the first segment and
-- passes the rest verbatim as the OpenRouter model slug.

local compat = require("psi.providers.openai_compat")
local prelude = require("psi.prelude")
local stream_parser = require("psi.stream_parser")

local M = {}

local API_KEY_ENV = "OPENROUTER_API_KEY"
local BASE_URL_ENV = "PSI_OPENROUTER_BASE_URL"
local BASE_URL_DEFAULT = "https://openrouter.ai/api/v1/"
local MODEL_ENV = "PSI_OPENROUTER_MODEL"
local MODEL_DEFAULT = "google/gemini-3-flash-preview"
local REFERER_ENV = "PSI_OPENROUTER_REFERER"
local TITLE_ENV = "PSI_OPENROUTER_TITLE"

local safe_decode = prelude.safe_json_decode

local function api_url(path)
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. path
end

local function resolve_model(m)
  if m and m ~= "" then
    return m
  end
  return os.getenv(MODEL_ENV) or MODEL_DEFAULT
end

local function headers()
  local key = os.getenv(API_KEY_ENV) or ""
  local hdrs = {
    "Content-Type: application/json",
    "Authorization: Bearer " .. key,
  }
  -- Optional OpenRouter attribution; opt-in via env.
  local referer = os.getenv(REFERER_ENV)
  if referer and referer ~= "" then
    hdrs[#hdrs + 1] = "HTTP-Referer: " .. referer
  end
  local title = os.getenv(TITLE_ENV)
  if title and title ~= "" then
    hdrs[#hdrs + 1] = "X-Title: " .. title
  end
  return hdrs
end

-- ---------- OpenAI-compat SSE streaming ----------
--
-- Wire format (one logical event per blank-line-terminated data):
--   data: {"id":"…","choices":[{"delta":{"content":"hi"}}]}
--   data: {"choices":[{"delta":{"tool_calls":[
--     {"index":0,"id":"call_x","type":"function",
--      "function":{"name":"bash","arguments":""}}]}}]}
--   data: {"choices":[{"delta":{"tool_calls":[
--     {"index":0,"function":{"arguments":"{\"cmd"}}]}}]}
--   …
--   data: {"choices":[{"finish_reason":"tool_calls"}],"usage":{…}}
--   data: [DONE]
--
-- Tool-call arguments arrive as JSON-string fragments keyed by
-- `index`; accumulate per-index then JSON-decode at finalize time.
local function new_state()
  return {
    text_parts = {},
    tool_calls_by_index = {}, -- [idx] = {id, name, arg_parts = {}}
    tool_calls_order = {}, -- emission order
    usage = nil,
    stop_reason = nil,
    response_id = nil,
    done = false,
  }
end

local function handle_event(data, state, observer)
  if data == "[DONE]" then
    state.done = true
    return
  end
  local obj = safe_decode(data)
  if type(obj) ~= "table" then
    return
  end
  state.response_id = state.response_id or obj.id

  local choices = obj.choices
  if type(choices) == "table" and choices[1] then
    local ch = choices[1]
    local delta = ch.delta
    if type(delta) == "table" then
      if type(delta.content) == "string" and delta.content ~= "" then
        state.text_parts[#state.text_parts + 1] = delta.content
        state.text = nil
        if observer.on_assistant_text_delta then
          observer.on_assistant_text_delta(delta.content)
        end
        if psi.events then
          psi.events.emit("assistant-text-delta", { text = delta.content })
        end
      end
      if type(delta.tool_calls) == "table" then
        for _, tc in ipairs(delta.tool_calls) do
          local idx = tc.index
          if type(idx) == "number" then
            local slot = state.tool_calls_by_index[idx]
            if not slot then
              slot = { id = nil, name = nil, arg_parts = {} }
              state.tool_calls_by_index[idx] = slot
              state.tool_calls_order[#state.tool_calls_order + 1] = idx
            end
            if tc.id and tc.id ~= "" then
              slot.id = tc.id
            end
            local fn = tc["function"]
            if type(fn) == "table" then
              if type(fn.name) == "string" and fn.name ~= "" then
                slot.name = fn.name
              end
              if type(fn.arguments) == "string" then
                slot.arg_parts[#slot.arg_parts + 1] = fn.arguments
              end
            end
          end
        end
      end
    end
    if ch.finish_reason then
      state.stop_reason = ch.finish_reason
    end
  end

  -- Usage arrives on a trailing chunk when stream_options.include_usage
  -- is set. OpenRouter sometimes conflates prior cache hits with the
  -- current response in `cached_tokens`; subtract cache_write to
  -- isolate cache_read, matching pi-mono's handling.
  if type(obj.usage) == "table" then
    state.usage = {
      input_tokens = obj.usage.prompt_tokens or 0,
      output_tokens = obj.usage.completion_tokens or 0,
    }
    local ptd = obj.usage.prompt_tokens_details
    if type(ptd) == "table" then
      local cached = tonumber(ptd.cached_tokens) or 0
      state.usage.cache_read = cached
      state.usage.input_tokens = math.max(0, (state.usage.input_tokens or 0) - cached)
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

local function finalize_tool_calls(state)
  local out = {}
  for _, idx in ipairs(state.tool_calls_order) do
    local slot = state.tool_calls_by_index[idx]
    if slot and slot.name then
      local arg_json = table.concat(slot.arg_parts)
      local args
      if #arg_json > 0 then
        args = safe_decode(arg_json)
        if type(args) ~= "table" then
          -- Truncated/malformed args: surface via stream_error so the
          -- turn fails instead of dispatching with empty input.
          state.malformed_tool_input_error = state.malformed_tool_input_error
            or string.format(
              "tool call %s (%s) has malformed arguments (%d bytes, starts with %q)",
              slot.name or "?",
              slot.id or "?",
              #arg_json,
              arg_json:sub(1, 48)
            )
          args = {}
        end
      else
        args = {}
      end
      local id = slot.id
      if not id or id == "" then
        id = "call_" .. prelude.uuid_short():sub(1, 12)
      end
      out[#out + 1] = { id = id, name = slot.name, arguments = args }
    end
  end
  return out
end

-- ---------- Provider config ----------

local function make_config(model)
  return {
    provider_name = "openrouter",
    api_name = "openrouter-chat-completions",
    url = api_url("chat/completions"),
    headers = headers(),
    include_response_id = true,

    request_body = function(args)
      local body = {
        model = args.model,
        messages = args.messages,
        tools = args.tool_specs,
        stream = true,
        stream_options = { include_usage = true },
      }
      if args.max_tokens then
        body.max_tokens = args.max_tokens
      end
      return body
    end,

    parser_new = stream_parser.sse_parser,
    parser_push = parser_push,
    new_state = new_state,
    finalize_tool_calls = finalize_tool_calls,
    stream_error = function(state)
      if state.malformed_tool_input_error then
        return "openrouter: " .. state.malformed_tool_input_error
      end
      return nil
    end,

    tool_result_message = function(tool_call_id, tool_name, text)
      local msg = { role = "tool", content = text }
      if tool_call_id and tool_call_id ~= "" then
        msg.tool_call_id = tool_call_id
      end
      return msg
    end,

    assistant_tool_call = function(b)
      return {
        id = b.id,
        type = "function",
        ["function"] = {
          name = b.name,
          arguments = psi.json_encode(b.arguments or {}),
        },
      }
    end,

    extract_completion = function(parsed)
      local choice = (parsed.choices or {})[1]
      if type(choice) ~= "table" or type(choice.message) ~= "table" then
        return ""
      end
      return choice.message.content or ""
    end,
  }
end

-- ---------- Public entry points ----------

function M.run_turn(opts)
  local model = resolve_model(opts.model)
  return compat.run_turn({
    model = model,
    observer = opts.observer,
    abort_check = opts.abort_check,
    max_tokens = opts.max_tokens,
    system_prompt = opts.system_prompt,
    tool_specs = opts.tool_specs,
  }, make_config(model))
end

function M.complete_text(opts)
  local model = resolve_model(opts.model)
  return compat.complete_text({
    model = model,
    system_prompt = opts.system_prompt,
    user_text = opts.user_text,
    abort_check = opts.abort_check,
    max_tokens = opts.max_tokens,
  }, make_config(model))
end

return M
