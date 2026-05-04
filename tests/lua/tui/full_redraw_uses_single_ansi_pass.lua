--[==[psi-test
expect = "1|1|true|0|true|0|0|0|0|0"
]==]
local d = require("psi.tui_runtime")._debug_redraw_counts("hello\nhi")
return table.concat({
  tostring(d.first_frames),
  tostring(d.second_frames),
  tostring(d.second_input_draws > 0),
  tostring(d.second_clears),
  tostring(d.stale_clears > 0),
  tostring(d.line_clears),
  tostring(d.draw_rows),
  tostring(d.raw_draws),
  tostring(d.cursor_sets),
  tostring(d.refreshes)
}, "|")
