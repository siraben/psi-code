--[==[psi-test
expect = "true|2|thinking|extension output"
]==]
local commands = require("psi.slash_commands")
local records = require("psi.records")
local rt = require("psi.tui_runtime")
commands.register("busy-ext", function()
  return records.new_command_action("print", "extension output")
end)
local state = rt._debug_edit_keys("/busy-ext", 9, { { key = "enter" } }, false, {
  busy = true,
  entries = { { kind = "thinking", text = "still thinking" } },
})
return table.concat({
  tostring(state.busy),
  tostring(state.entry_count),
  tostring(state.first_entry_kind),
  tostring(state.last_entry_text),
}, "|")
