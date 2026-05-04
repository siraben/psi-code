--[==[psi-test
expect = "false|19|true|18|20|true|18"
]==]
local rt = require("psi.tui_runtime")
local idle = rt._debug_layout_rows(80, 24, false, nil)
local busy = rt._debug_layout_rows(80, 24, true, nil)
local status = rt._debug_layout_rows(80, 24, false, "saved")
return table.concat({
  tostring(idle.status_visible), tostring(idle.transcript_height),
  tostring(busy.status_visible), tostring(busy.transcript_height), tostring(busy.status_row),
  tostring(status.status_visible), tostring(status.transcript_height)
}, "|")
