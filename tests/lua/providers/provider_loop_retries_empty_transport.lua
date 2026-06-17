--[==[psi-test
expect = "true|2|reply 2"
]==]
local provider_loop = require("psi.provider_loop")

local requests = 0

psi.http_stream_begin = function()
  requests = requests + 1
  return { id = requests }
end
psi.http_stream_poll = function()
  return nil, true
end
psi.http_stream_finish = function(handle)
  if handle.id == 1 then
    return -1, "Empty reply from server"
  end
  return 200
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
      return {}
    end,
    parser_new = function()
      return {}
    end,
    parser_push = function() end,
    finalize = function()
      return "reply " .. tostring(requests), {}
    end,
    persist = function() end,
    has_partial = function()
      return false
    end,
    text = function()
      return "reply " .. tostring(requests)
    end,
    after_iteration = function() end,
    classify_http_error = function(status)
      return "status " .. tostring(status)
    end,
  })
end)

return tostring(ok) .. "|" .. tostring(requests) .. "|" .. tostring(text)
