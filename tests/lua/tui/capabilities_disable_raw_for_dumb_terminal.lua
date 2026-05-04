--[==[psi-test
expect = "false|false|false"
env = { TERM = "dumb" }
]==]
local caps = require("psi.tui_runtime")._debug_tui_capabilities()
return table.concat({tostring(caps.ansi), tostring(caps.color), tostring(caps.raw_ansi)}, "|")
