--[==[psi-test
expect = "7|5|4|4|1|true|true|1|1|1|true|true|8|8|2|true|true|18"
]==]
local rt = require("psi.tui_runtime")

local standard_layout = rt._debug_resolve_input_layout(80, 24)
local tiny_layout = rt._debug_resolve_input_layout(20, 4)
local multiline = table.concat({ "one", "two", "three", "four", "five", "six" }, "\n")
local four = rt._debug_redraw_counts(multiline, {
  width = 20,
  height = 4,
  show_hardware_cursor = true,
})
local one = rt._debug_redraw_counts(multiline, {
  width = 20,
  height = 1,
  show_hardware_cursor = true,
})
local eight = rt._debug_redraw_counts(multiline, {
  width = 20,
  height = 8,
  show_hardware_cursor = true,
})
local capped_input = rt._debug_resolve_input_layout(20, 80, false, 0, 24)

return table.concat({
  standard_layout.max_rows,
  tiny_layout.max_rows,
  four.viewport_height,
  four.first_height,
  four.first_input_rows,
  tostring(four.first_row >= 1 and four.first_row <= four.first_height),
  tostring(four.first_visible),
  one.viewport_height,
  one.first_height,
  one.first_row,
  tostring(one.first_col >= 1 and one.first_col <= 20),
  tostring(one.first_visible),
  eight.viewport_height,
  eight.first_height,
  eight.first_input_rows,
  tostring(eight.first_row >= 1 and eight.first_row <= eight.first_height),
  tostring(eight.first_visible),
  capped_input.effective_max_rows,
}, "|")
