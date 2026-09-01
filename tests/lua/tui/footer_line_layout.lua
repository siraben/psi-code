--[==[psi-test
expect = "19|21|17|19|2|19|21"
]==]
local rt = require("psi.tui_runtime")
local tui = require("psi.tui_status")
local idle = rt._debug_layout_rows(80, 24, false, nil)
tui.register_footer_line(function()
  return "agents: 3 running"
end)
tui.register_footer_line(function()
  return "queue: 2 waiting"
end)
local hooked = rt._debug_layout_rows(80, 24, false, nil)
tui.clear_footer_line_hooks()
local cleared = rt._debug_layout_rows(80, 24, false, nil)
return table.concat({
  tostring(idle.transcript_height),
  tostring(idle.input_start_row),
  tostring(hooked.transcript_height),
  tostring(hooked.input_start_row),
  tostring(hooked.footer_extra_rows),
  tostring(cleared.transcript_height),
  tostring(cleared.input_start_row),
}, "|")
