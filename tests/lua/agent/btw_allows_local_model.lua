--[==[psi-test
expect = "true|qwen2.5"
]==]
local agent = require("psi.agent_session")
local ollama = require("psi.providers.ollama")
ollama.complete_text = function(opts) return true, opts.model end
agent.configure({model = "ollama/qwen2.5"})
local ok, answer = agent.side_question("should not call the network")
return tostring(ok) .. "|" .. tostring(answer)
