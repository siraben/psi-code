--[==[psi-test
expect = "toggle-thinking|false|true|true|true"
]==]
local tui = require("psi.tui_status")
local runtime = require("psi.tui_runtime")
local key = tui.handle_key({ key = "ctrl-t", busy = false, input_length = 0 })
local once = runtime._debug_edit_keys("", 0, { { key = "ctrl-t" } })
local twice = runtime._debug_edit_keys("", 0, { { key = "ctrl-t" }, { key = "ctrl-t" } })
local visible = table.concat(runtime._debug_thinking_lines("secret reasoning", true), "\n")
local hidden = table.concat(runtime._debug_thinking_lines("secret reasoning", false), "\n")
return table.concat({
  key.action,
  tostring(once.show_thinking),
  tostring(twice.show_thinking),
  tostring(visible:find("secret reasoning", 1, true) ~= nil),
  tostring(hidden:find("Thinking...", 1, true) ~= nil
    and hidden:find("secret reasoning", 1, true) == nil),
}, "|")
