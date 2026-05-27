--[==[psi-test
expect = ">.hello..\n|.world.\n|.end|3|3|6"
]==]
local rt = require("psi.tui_runtime")
local input = "hello   world end"
local d = rt._debug_input_lines(input, #input, 10, "> ", "| ")
return table.concat({
  table.concat(d.lines, "\n"):gsub(" ", "."),
  tostring(d.cursor_line),
  tostring(d.cursor_col),
  tostring(d.cursor_screen_col),
}, "|")
