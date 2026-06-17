--[==[psi-test
expect = "false|1|1|http transport error: Empty reply from server"
]==]
local provider_loop = require("psi.provider_loop")

local requests = 0
local polls = 0
local saved = 0

psi.http_stream_begin = function()
  requests = requests + 1
  return { id = requests }
end
psi.http_stream_poll = function()
  polls = polls + 1
  if polls == 1 then
    return "partial", false
  end
  return nil, true
end
psi.http_stream_finish = function()
  return -1, "Empty reply from server"
end

local ok, text = require("psi.sched").run(function()
  return provider_loop.run_turn({
    max_retries = 2,
    initial_retry_delay_ms = 0,
  }, {
    provider_name = "fake",
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
    new_state = function()
      return { text = "" }
    end,
    parser_new = function()
      return {}
    end,
    parser_push = function(_, chunk, state)
      state.text = state.text .. chunk
    end,
    finalize = function(state)
      return state.text, {}
    end,
    save_failed_partial = function()
      saved = saved + 1
    end,
    text = function(state)
      return state.text
    end,
    after_iteration = function() end,
    classify_http_error = function(status)
      return "status " .. tostring(status)
    end,
  })
end)

return tostring(ok) .. "|" .. tostring(requests) .. "|" .. tostring(saved) .. "|" .. tostring(text)
