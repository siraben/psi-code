--[==[psi-test
expect = "/help|/he||info|true|false"
]==]
local rt = require("psi.tui_runtime")
local tab = rt._debug_edit_keys("/he", 3, { { key = "tab" } }, false)
local escape = rt._debug_edit_keys("/he", 3, { { key = "escape" } }, false)
local enter = rt._debug_edit_keys("/he", 3, { { key = "enter" } }, false)
local tools = rt._debug_edit_keys("", 0, { { key = "ctrl-o" }, { key = "ctrl-o" } }, false)
return table.concat({
  tab.input,
  escape.input,
  enter.input,
  enter.last_entry_kind or "",
  tostring(
    enter.last_entry_text and enter.last_entry_text:find("available commands", 1, true) ~= nil
  ),
  tostring(tools.tools_expanded),
}, "|")
