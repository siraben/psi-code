--[==[psi-test
expect = "true|2|thinking|partial reasoning|info|true"
]==]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys("/session", 8, { { key = "enter" } }, false, {
  busy = true,
  entries = { { kind = "thinking", text = "partial reasoning" } },
})
return table.concat({
  tostring(state.busy),
  tostring(state.entry_count),
  tostring(state.first_entry_kind),
  tostring(state.first_entry_text),
  tostring(state.last_entry_kind),
  tostring(
    type(state.last_entry_text) == "string" and state.last_entry_text:find("id:", 1, true) ~= nil
  ),
}, "|")
