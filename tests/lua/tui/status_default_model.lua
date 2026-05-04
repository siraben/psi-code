--[==[psi-test
contains = "model:"
not_contains = "model:?"
]==]
local tui = require("psi.tui_status")
return tui.status_line(psi.json_encode({busy=false, scroll=0}))
