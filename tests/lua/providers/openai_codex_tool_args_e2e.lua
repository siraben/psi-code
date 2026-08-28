--[==[psi-test
expect = "true|true|true|true|true|true|true|true|true|true|true|true|true|true"
]==]
local codex = require("psi.providers.openai_codex")._debug
local provider_loop = require("psi.provider_loop")
local prelude = require("psi.prelude")
local render = require("psi.render")
require("psi.tools")

local function event(t)
  return "data: " .. psi.json_encode(t) .. "\n\n"
end

local function split_chunks(text)
  local out = {}
  local cuts = { 1, 2, 5, 13, 29, 47 }
  local pos = 1
  local idx = 1
  while pos <= #text do
    local n = cuts[((idx - 1) % #cuts) + 1]
    out[#out + 1] = text:sub(pos, pos + n - 1)
    pos = pos + n
    idx = idx + 1
  end
  return out
end

local function state_text(state)
  local out = {}
  for _, block in ipairs(state.blocks or {}) do
    if block.kind == "text" then
      out[#out + 1] = table.concat(block.text_parts or {})
    end
  end
  return table.concat(out)
end

local function run_case(command, opts)
  opts = opts or {}
  local requests = 0
  local observed = {
    calls = {},
    results = {},
    call_renders = {},
    result_renders = {},
  }
  local final_args = psi.json_encode({ command = command })
  local stale_done_args = psi.json_encode({ command = opts.stale_done_command or "printf STALE_DONE" })
  local first_stream = table.concat({
    event({
      type = "response.output_item.added",
      output_index = 0,
      item = {
        type = "function_call",
        id = "fc_1",
        call_id = "call_1",
        name = "bash",
        arguments = "",
      },
    }),
    event({
      type = "response.function_call_arguments.delta",
      output_index = 0,
      delta = final_args:sub(1, 7),
    }),
    -- Leave the final command byte plus the closing quote/brace out of the
    -- deltas. Only the authoritative terminal item supplies them.
    event({
      type = "response.function_call_arguments.delta",
      output_index = 0,
      delta = final_args:sub(8, #final_args - 3),
    }),
    event({
      type = "response.function_call_arguments.done",
      output_index = 0,
      arguments = stale_done_args,
    }),
    event({
      type = "response.output_item.done",
      output_index = 0,
      item = {
        type = "function_call",
        id = "fc_1",
        call_id = "call_1",
        name = "bash",
        arguments = final_args,
      },
    }),
    event({
      type = "response.completed",
      response = {
        status = "completed",
        usage = {
          input_tokens = 1,
          output_tokens = 1,
          input_tokens_details = { cached_tokens = 0 },
        },
      },
    }),
  })
  local second_stream = table.concat({
    event({
      type = "response.output_item.added",
      output_index = 0,
      item = { type = "message", id = "msg_1" },
    }),
    event({
      type = "response.output_text.delta",
      output_index = 0,
      delta = "done",
    }),
    event({
      type = "response.output_item.done",
      output_index = 0,
      item = {
        type = "message",
        id = "msg_1",
        content = { { type = "output_text", text = "done" } },
      },
    }),
    event({
      type = "response.completed",
      response = {
        status = "completed",
        usage = {
          input_tokens = 1,
          output_tokens = 1,
          input_tokens_details = { cached_tokens = 0 },
        },
      },
    }),
  })
  local streams = { split_chunks(first_stream), split_chunks(second_stream) }

  psi.http_stream_begin = function()
    requests = requests + 1
    return { id = requests, pos = 1 }
  end
  psi.http_stream_poll = function(handle)
    local chunks = streams[handle.id] or {}
    local chunk = chunks[handle.pos]
    if chunk then
      handle.pos = handle.pos + 1
      return chunk, false
    end
    return nil, true
  end
  psi.http_stream_finish = function()
    return 200
  end

  local observer = {
    on_tool_call = function(id, name, input_json)
      local input = prelude.safe_json_decode(input_json) or {}
      observed.calls[#observed.calls + 1] = { id = id, name = name, input = input }
      observed.call_renders[#observed.call_renders + 1] =
        render.render_tool_call({ id = id, tool = name, input = input })
    end,
    on_tool_result = function(id, name, result_json)
      local result = prelude.safe_json_decode(result_json) or {}
      observed.results[#observed.results + 1] = { id = id, name = name, result = result }
      observed.result_renders[#observed.result_renders + 1] =
        render.render_tool_result({ id = id, tool = name, result = result })
    end,
  }

  local ok, text = require("psi.sched").run(function()
    return provider_loop.run_turn({
      observer = observer,
      max_retries = 0,
      initial_retry_delay_ms = 0,
    }, {
      provider_name = "openai-codex",
      url = "https://example.invalid",
      headers = {},
      tool_specs = function()
        return {}
      end,
      build_messages = function(messages)
        return messages
      end,
      request_body = function(args)
        return { messages = args.messages }
      end,
      new_state = codex.new_state,
      parser_new = codex.parser_new,
      parser_push = codex.parser_push,
      finalize = codex.finalize,
      persist = function() end,
      has_partial = function(state, tool_calls)
        return state_text(state) ~= "" or #tool_calls > 0
      end,
      text = state_text,
      after_iteration = function() end,
      classify_http_error = function(status)
        return "status " .. tostring(status)
      end,
      stream_error = function(state)
        return state.malformed_tool_input_error
      end,
    })
  end)
  observed.ok = ok
  observed.text = text
  observed.requests = requests
  return observed
end

local valid = run_case("printf CODEX_OK", { stale_done_command = "printf STALE_DONE" })
local control_byte = string.char(15)
local control_command = "printf 'CONTROL=%s' 'prin" .. control_byte .. "'"
local control = run_case(control_command, { stale_done_command = "printf STALE_DONE" })

local valid_call = valid.calls[1] or { input = {} }
local valid_result = (valid.results[1] or {}).result or {}
local valid_call_render = valid.call_renders[1] or ""
local valid_result_render = valid.result_renders[1] or ""
local control_call = control.calls[1] or { input = {} }
local control_result = (control.results[1] or {}).result or {}
local control_call_render = control.call_renders[1] or ""
local control_result_render = control.result_renders[1] or ""

return table.concat({
  tostring(valid.ok == true),
  tostring(valid.text == "done"),
  tostring(valid.requests == 2),
  tostring(valid_call.input.command == "printf CODEX_OK"),
  tostring(valid_result.ok == true and valid_result.output == "CODEX_OK"),
  tostring(valid_call_render:find("CODEX_OK", 1, true) ~= nil),
  tostring(valid_result_render:find("CODEX_OK", 1, true) ~= nil),
  tostring(control.ok == true),
  tostring(control.requests == 2),
  tostring(control_call.input.command == control_command),
  tostring(control_result.ok == true),
  tostring(control_result.output == "CONTROL=prin" .. control_byte),
  tostring(control_call_render:find("prin\\x0F", 1, true) ~= nil),
  tostring(control_result_render:find("CONTROL=prin", 1, true) ~= nil),
}, "|")
