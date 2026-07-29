--[==[psi-test
expect = "compact,turn"
]==]
local agent = require("psi.agent_session")
local context = require("psi.context")
local runtime = require("psi.agent_session_runtime")

local events = {}
local checks = 0
agent.model_descriptor = function()
  return { id = "claude-opus-4-8", provider = "anthropic", context_window = 1000000 }
end
agent.run_compact = function()
  events[#events + 1] = "compact"
  return true, "summary"
end
agent.run_turn = function()
  events[#events + 1] = "turn"
  return true, "ok"
end
context.should_compact = function()
  checks = checks + 1
  return checks == 1, { tokens = 990000 }
end
context.usage_exceeds_window = function()
  return false
end

runtime.new({ model = "anthropic/claude-opus-4-8" }):turn("hello")
return table.concat(events, ",")
