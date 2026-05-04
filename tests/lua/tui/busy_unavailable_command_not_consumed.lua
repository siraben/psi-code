--[[psi-test
expect = "/model x|command unavailable while busy"
]]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys("/model x", 8, {{key="enter"}}, false, {busy=true})
return state.input .. "|" .. tostring(state.status_text)
