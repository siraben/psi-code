--[==[psi-test
expect = ">.hello.\n|.world.test|2|10|13"
]==]
local rt = require("psi.tui_runtime")
local input = "hello world test"
local d = rt._debug_input_lines(input, #input, 14, "> ", "| ")
return table.concat({
  table.concat(d.lines, "\n"):gsub(" ", "."),
  tostring(d.cursor_line),
  tostring(d.cursor_col),
  tostring(d.cursor_screen_col),
}, "|")
