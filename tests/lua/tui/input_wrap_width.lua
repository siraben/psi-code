--[==[psi-test
expect = "2|79|3|2|1"
]==]
local d = require("psi.tui_runtime")._debug_input_lines(
  string.rep("a", 78), 78, 80, "> ", "| ")
return table.concat({
  tostring(#d.lines),
  tostring(#d.lines[1]),
  tostring(#d.lines[2]),
  tostring(d.cursor_line),
  tostring(d.cursor_col)
}, "|")
