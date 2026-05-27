--[==[psi-test
expect = "true|true|true"
env = { OS = "Windows_NT", TERM = "" }
]==]
local caps = require("psi.tui_runtime")._debug_tui_capabilities()
return table.concat({ tostring(caps.ansi), tostring(caps.color), tostring(caps.raw_ansi) }, "|")
