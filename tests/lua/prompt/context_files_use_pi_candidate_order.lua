--[==[psi-test
expect = "true|false|true"
cwd = "ctx-order"
files = [
  { path = "AGENTS.MD", text = "uppercase agents wins" },
  { path = "CLAUDE.md", text = "claude should not load from same dir" },
]
]==]
local sp = require("psi.prompt").system_prompt()
return tostring(sp:find("uppercase agents wins", 1, true) ~= nil) .. "|"
  .. tostring(sp:find("claude should not load", 1, true) ~= nil) .. "|"
  .. tostring(sp:find("<project_instructions path=", 1, true) ~= nil)
