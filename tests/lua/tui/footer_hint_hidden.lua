--[==[psi-test
expect = "|working (0:04  • Ctrl-G to interrupt) .."
]==]
local tui = require("psi.tui_status")
local idle = tui.footer_hint(psi.json_encode({busy=false, scroll=0}))
local busy = tui.footer_hint(psi.json_encode({
  busy=true, busy_label="working", elapsed_seconds=4, busy_phase=2, scroll=0
}))
return tostring(idle) .. "|" .. tostring(busy)
