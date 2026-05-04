--[==[psi-test
expect = "nil|/btw laterx"
]==]
local d = require("psi.tui_runtime")._debug_edit_keys("/btw later", 10, {{key="enter"}, {key="text", text="x"}}, false, {busy=true, busy_kind="agent"})
return tostring(d.status_text) .. "|" .. d.input
