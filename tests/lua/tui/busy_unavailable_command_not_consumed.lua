--[==[psi-test
expect = "|true|info|model set to test-provider/test-model"
]==]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys(
  "/model test-provider/test-model",
  31,
  { { key = "enter" } },
  false,
  { busy = true }
)
return table.concat({
  state.input,
  tostring(state.busy),
  tostring(state.last_entry_kind),
  tostring(state.last_entry_text),
}, "|")
