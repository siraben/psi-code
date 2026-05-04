--[==[psi-test
expect = "true|true|true"
env = { TERM = "xterm-256color", PSI_COLOR = "1" }
]==]
local caps = require("psi.tui_runtime")._debug_tui_capabilities()
return table.concat({tostring(caps.ansi), tostring(caps.color), tostring(caps.raw_ansi)}, "|")
