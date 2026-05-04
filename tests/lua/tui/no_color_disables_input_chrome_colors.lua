--[==[psi-test
expect = "true|true"
env = { NO_COLOR = "1", TERM = "xterm-256color" }
]==]
local d = require("psi.tui_runtime")._debug_redraw_counts("hello")
local frame = d.second_frame or ""
return table.concat({
  tostring(frame:find("48;5;", 1, true) == nil),
  tostring(frame:find("38;5;", 1, true) == nil)
}, "|")
