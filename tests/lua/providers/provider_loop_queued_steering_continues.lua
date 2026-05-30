--[==[psi-test
expect = "true|2|0|start,steer now"
]==]
local session = require("psi.session_manager")
local control = require("psi.agent_control")
local provider_loop = require("psi.provider_loop")

psi.session_clear()
control.clear_queues()
session.append_user("start")

local requests = 0
local queued = false

psi.http_stream_begin = function()
  requests = requests + 1
  return { id = requests }
end
psi.http_stream_poll = function(handle)
  if handle.id == 1 and not queued then
    queued = true
    control.queue_steering("steer now")
  end
  return nil, true
end
psi.http_stream_finish = function()
  return 200
end

local function user_texts()
  local out = {}
  for _, message in ipairs(session.messages()) do
    if message.role == "user" then
      out[#out + 1] = message.text or ""
    end
  end
  return table.concat(out, ",")
end

local ok = require("psi.sched").run(function()
  return provider_loop.run_turn({}, {
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
    persist = function(_, _, content)
      session.append_assistant(content or "")
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

return tostring(ok) .. "|" .. tostring(requests) .. "|"
  .. tostring(control.pending_count()) .. "|" .. user_texts()
