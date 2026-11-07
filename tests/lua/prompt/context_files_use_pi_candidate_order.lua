--[==[psi-test
expect = "true|false|true"
cwd = "ctx-order"
files = [
  { path = "AGENTS.MD", text = "uppercase agents wins" },
  { path = "CLAUDE.md", text = "claude should not load from same dir" },
]
]==]
local prompt = require("psi.prompt")
local sp = prompt.system_prompt()
assert(psi.file_write(psi.path_join(psi.cwd(), "AGENTS.override.md"), "\239\187\191override rules"))
local override = prompt.system_prompt()
assert(override:find("override rules", 1, true))
assert(not override:find("uppercase agents wins", 1, true))
assert(not override:find("\239\187\191", 1, true), "context-file BOM is not prompt content")
return tostring(sp:find("uppercase agents wins", 1, true) ~= nil)
  .. "|"
  .. tostring(sp:find("claude should not load", 1, true) ~= nil)
  .. "|"
  .. tostring(sp:find("<project_instructions path=", 1, true) ~= nil)
