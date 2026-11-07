--[==[psi-test
expect = "true|true"
cwd = "system-files"
files = [
  { path = ".psi/SYSTEM.md", text = "Custom psi system base." },
  { path = ".psi/APPEND_SYSTEM.md", text = "Additional psi system guidance." },
]
]==]
local prompt = require("psi.prompt")
local sp = prompt.system_prompt()
local session = require("psi.session_manager")
assert(prompt.prepare_checkpoint() == sp)
local leaf = session.leaf_id()
assert(prompt.prepare_checkpoint() == sp and session.leaf_id() == leaf)
require("psi.tool_registry").set_active({ "read" })
prompt.prepare_checkpoint()
assert(session.leaf_id() ~= leaf)
local system = session.current_system()
assert(#system.toolsAdded == 1 and system.toolsAdded[1].name == "read")
assert(system.sections.preamble:find("Custom psi system base.", 1, true))
local raw = session.projection().path
assert(#raw[#raw].message.toolsRemoved > 0)
return tostring(sp:find("Custom psi system base.", 1, true) ~= nil)
  .. "|"
  .. tostring(sp:find("Additional psi system guidance.", 1, true) ~= nil)
