--[==[psi-test
expect = "xhigh|nil|medium"
cwd = "codex-reasoning-config"
env = { PSI_OPENAI_CODEX_REASONING = "", PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { defaults = { reasoning_effort = "medium" } } },
]
]==]
local d = require("psi.providers.openai_codex")._debug
local a = d.request_body({model="gpt-5.5", messages={}, reasoning_effort="xhigh"})
local b = d.request_body({model="gpt-5.5", messages={}, reasoning_effort="none"})
local c = d.request_body({model="gpt-5.5", messages={}})
return a.reasoning.effort .. "|" .. tostring(b.reasoning) .. "|" .. c.reasoning.effort
