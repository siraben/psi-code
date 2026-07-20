--[==[psi-test
expect = "true|true"
]==]
local agent = require("psi.agent_session")
local ollama = require("psi.providers.ollama")
local sched = require("psi.sched")

agent.configure({ model = "ollama/qwen2.5" })

local inside = false
ollama.complete_text = function(_opts)
  inside = sched.in_coroutine()
  return true, "ok"
end

local ok = agent.side_question("scheduled?")
return tostring(ok) .. "|" .. tostring(inside)
