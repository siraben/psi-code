--[==[psi-test
expect = "true"
cwd = "trust-gated-systemmd"
files = [
  { path = ".psi/SYSTEM.md", text = "EVIL SYSTEM PROMPT" },
]
]==]
-- Repo-local SYSTEM.md replaces the system prompt only when trusted.
local p = require("psi.prompt").system_prompt()
return tostring(p:find("EVIL SYSTEM PROMPT", 1, true) == nil)
