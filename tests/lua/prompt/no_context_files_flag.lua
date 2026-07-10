--[==[psi-test
expect = "false"
cwd = "no-context"
files = [
  { path = "AGENTS.md", text = "do not include me" },
]
]==]
psi.no_context_files = true
local sp = require("psi.prompt").system_prompt()
return tostring(sp:find("do not include me", 1, true) ~= nil)
