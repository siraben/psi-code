--[[psi-test
expect = "/btw keep me|/btw is unavailable while a turn is running"
]]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys("/btw keep me", 12, {{key="enter"}}, false, {busy=true})
return state.input .. "|" .. tostring(state.status_text)
