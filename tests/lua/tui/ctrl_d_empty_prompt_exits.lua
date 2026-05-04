--[==[psi-test
expect = "false|"
]==]
local d = require("psi.tui_runtime")._debug_edit_keys("", 0, {{key="ctrl-d"}}, false)
return tostring(d.running) .. "|" .. d.input
