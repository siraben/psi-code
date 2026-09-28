--[==[psi-test
expect = "|nil|warning|Wait for the current response to finish before asking a side question."
]==]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys("/btw keep me", 12, { { key = "enter" } }, false, { busy = true })
return table.concat({
  state.input,
  tostring(state.status_text),
  tostring(state.last_entry_kind),
  tostring(state.last_entry_text),
}, "|")
