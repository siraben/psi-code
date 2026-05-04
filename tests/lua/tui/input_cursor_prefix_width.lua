--[[psi-test
expect = "4"
]]
local d = require("psi.tui_runtime")._debug_input_lines(
  "abc", 0, 80, " › ", "   ")
return tostring(d.cursor_screen_col)
