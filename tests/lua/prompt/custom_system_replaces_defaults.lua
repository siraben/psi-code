--[==[psi-test
expect = "true|false|false|true"
cwd = "custom-system-replaces"
files = [
  { path = ".psi/SYSTEM.md", text = "Project-defined system prompt." },
  { path = ".psi/APPEND_SYSTEM.md", text = "Project-defined addendum." },
]
]==]
local prompt = require("psi.prompt").system_prompt()
return tostring(prompt:find("Project-defined system prompt.", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("Available tools:", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("Psi documentation", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("Project-defined addendum.", 1, true) ~= nil)
