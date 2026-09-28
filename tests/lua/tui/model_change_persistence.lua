--[==[psi-test
expect = "ollama/test-model|1"
]==]
local session = require("psi.session_manager")
local agent = require("psi.agent_session")
local changed, saves = nil, 0
session.append_model_change = function(model)
  changed = model
end
session.save = function()
  saves = saves + 1
end
agent.configure({ model = "ollama/initial" })
agent.set_model("ollama/test-model")
agent.set_model("ollama/test-model")
agent.set_model(nil)
return changed .. "|" .. saves
