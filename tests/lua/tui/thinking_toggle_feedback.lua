--[==[psi-test
expect = "true|true|info|Thinking blocks: visible"
]==]
local runtime = require("psi.tui_runtime")
local result = runtime._debug_edit_keys("", 0, {
  { key = "ctrl-t" },
  { key = "ctrl-t" },
})
return table.concat({
  tostring(result.show_thinking),
  tostring(result.status_text == nil),
  tostring(result.last_entry_kind),
  tostring(result.last_entry_text),
}, "|")
