--[[psi-test
expect = "1|1|/new|command unavailable while busy"
]]
local rt = require("psi.tui_runtime")
psi.session_append("user", "keep", nil)
local before = psi.session_message_count()
local state = rt._debug_edit_keys("/new", 4, {{key="enter"}}, false, {busy=true})
return table.concat({
  tostring(before),
  tostring(psi.session_message_count()),
  state.input,
  tostring(state.status_text)
}, "|")
