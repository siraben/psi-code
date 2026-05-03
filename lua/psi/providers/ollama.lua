-- psi.ollama: Ollama provider. Thin adapter over psi.openai_compat
-- — the OpenAI-compat skeleton handles session↔messages translation,
-- the streaming loop, concurrent tool dispatch, session persistence,
-- and event emission. This file supplies just the Ollama-specific
-- bits: base URL, request body shape, and the NDJSON line parser
-- that decodes Ollama's `{message:{content, tool_calls}, done}`
-- envelope.

local compat = require("psi.providers.openai_compat")
local prelude = require("psi.prelude")
local stream_parser = require("psi.stream_parser")

local M = {}

local MODEL_ENV = "PSI_OLLAMA_MODEL"
local MODEL_DEFAULT = "llama3.1:latest"
local BASE_URL_ENV = "PSI_OLLAMA_BASE_URL"
local BASE_URL_DEFAULT = "http://localhost:11434/"

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

-- ---------- Ollama NDJSON streaming ----------
--
-- Ollama writes one complete JSON object per newline. Tool calls
-- arrive as already-parsed objects (not fragmented JSON strings
-- like the OpenAI-compat wire format), so the state is much
-- simpler than OpenRouter's — no per-index accumulator.
local function new_state()
  return {
    text_parts = {},
    -- Ollama emits reasoning-model output in a separate `thinking`
    -- field (Qwen3, DeepSeek-R1, …) distinct from `content`. Keep
    -- its running accumulator here so openai_compat.persist_assistant
    -- can materialise a thinking content block in the session, and
    -- so the on_thinking_delta observer / thinking-delta event see
    -- parity with the Anthropic provider.
    thinking_parts = {},
    tool_calls = {}, -- [i] = {id, name, arguments}
    usage = nil,
    stop_reason = nil,
    done = false,
  }
end

local function handle_line(line, state, observer)
  local obj = safe_decode(line)
  if type(obj) ~= "table" then
    return
  end
  local msg = obj.message
  if type(msg) == "table" then
    if type(msg.content) == "string" and msg.content ~= "" then
      state.text_parts[#state.text_parts + 1] = msg.content
      state.text = nil
      if observer.on_assistant_text_delta then
        observer.on_assistant_text_delta(msg.content)
      end
      if psi.events then
        psi.events.emit("assistant-text-delta", { text = msg.content })
      end
    end
    if type(msg.thinking) == "string" and msg.thinking ~= "" then
      state.thinking_parts[#state.thinking_parts + 1] = msg.thinking
      state.thinking = nil
      if observer.on_thinking_delta then
        observer.on_thinking_delta(msg.thinking)
      end
      if psi.events then
        psi.events.emit("thinking-delta", { text = msg.thinking })
      end
    end
    if type(msg.tool_calls) == "table" then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or {}
        local args = fn.arguments or {}
        -- Some Ollama builds emit arguments as a JSON string;
        -- normalise to a table either way.
        if type(args) == "string" then
          args = prelude.safe_json_decode(args, {})
        end
        local id = tc.id
        if not id or id == "" then
          id = "call_" .. prelude.uuid_short():sub(1, 12)
        end
        state.tool_calls[#state.tool_calls + 1] = {
          id = id,
          name = fn.name or "",
          arguments = args,
        }
      end
    end
  end
  if obj.done then
    state.done = true
    if type(obj.prompt_eval_count) == "number" or type(obj.eval_count) == "number" then
      state.usage = {
        input_tokens = obj.prompt_eval_count or 0,
        output_tokens = obj.eval_count or 0,
      }
    end
    state.stop_reason = obj.done_reason or "stop"
  end
end

local function parser_push(parser, chunk, state, observer)
  stream_parser.push_lines(parser, chunk, function(line)
    if #line > 0 then
      handle_line(line, state, observer)
    end
  end)
end

local function finalize_tool_calls(state)
  return state.tool_calls
end

-- ---------- Provider config ----------

local function make_config(model)
  return {
    provider_name = "ollama",
    api_name = "ollama-chat",
    url = api_url("api/chat"),
    headers = { "Content-Type: application/json" },
    include_response_id = false,

    request_body = function(args)
      local body = {
        model = args.model,
        messages = args.messages,
        tools = args.tool_specs,
        stream = true,
        options = {},
      }
      if args.max_tokens then
        body.options.num_predict = args.max_tokens
      end
      return body
    end,

    parser_new = stream_parser.line_parser,
    parser_push = parser_push,
    new_state = new_state,
    finalize_tool_calls = finalize_tool_calls,

    tool_result_message = function(tool_call_id, tool_name, text)
      -- Ollama uses OpenAI-compat tool messages; some builds also
      -- accept `tool_name` but `tool_call_id` is the canonical key.
      local msg = { role = "tool", content = text }
      if tool_call_id and tool_call_id ~= "" then
        msg.tool_call_id = tool_call_id
      end
      if tool_name and tool_name ~= "" then
        msg.tool_name = tool_name
      end
      return msg
    end,

    -- Ollama accepts args as either a parsed object or a JSON string;
    -- pi-mono sends the parsed object, which is the shape Ollama
    -- matches against its own tool output. Stick with that.
    assistant_tool_call = function(b)
      return {
        id = b.id,
        ["function"] = {
          name = b.name,
          arguments = b.arguments or {},
        },
      }
    end,

    extract_completion = function(parsed)
      local msg = parsed.message
      if type(msg) ~= "table" then
        return ""
      end
      return msg.content or ""
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
