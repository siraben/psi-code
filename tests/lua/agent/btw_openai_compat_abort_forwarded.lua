--[[psi-test
expect = "true|true"
]]
local agent = require("psi.agent_session")
local compat = require("psi.providers.openai_compat")
local seen = "-"
compat.complete_text = function(opts)
  seen = tostring(type(opts.abort_check) == "function" and opts.abort_check())
  return true, "ok"
end
agent.configure({model = "ollama/qwen2.5"})
local ok = agent.side_question("abort?", { abort_check = function() return true end })
return tostring(ok) .. "|" .. seen
