--[==[psi-test
expect = "true|true|true"
]==]
local rt = require("psi.tui_runtime")
local calls = rt._debug_redraw_counts("x", { width = 4, height = 12 })

return table.concat({
  tostring(calls.first_frames > 0),
  tostring((calls.first_line_width or 0) <= 4),
  tostring((calls.first_col or 0) <= 4),
}, "|")
