--[==[psi-test
expect = "true|1|1|recovered"
]==]
local agent = require("psi.agent_session")
local context = require("psi.context")
local runtime = require("psi.agent_session_runtime")

local compact_count = 0
local continue_count = 0

agent.model_descriptor = function()
  return { id = "k3", provider = "moonshot", context_window = 1048576 }
end
agent.run_turn = function()
  return false, "Your request exceeded model token limit: 1048576 (requested: 1049000)"
end
agent.run_compact = function(opts)
  compact_count = compact_count + 1
  return opts.reason == "overflow", "summary"
end
agent.continue_turn = function()
  continue_count = continue_count + 1
  return true, "recovered"
end
context.should_compact = function()
  return false, { tokens = 1 }
end
context.usage_exceeds_window = function()
  return false
end

local instance = runtime.new({ model = "moonshot/k3" })
local ok, reply = instance:turn("hello")
return table.concat({
  tostring(ok),
  tostring(compact_count),
  tostring(continue_count),
  tostring(reply),
}, "|")
