--[==[psi-test
expect = "true|true|true"
]==]
-- The pi-light tool block must pair a pale success/pending background
-- with dark title text. The regression this guards against was a dark
-- green background (48;5;22) left unremapped under a light terminal,
-- which rendered black-on-dark-green and was unreadable.
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local te = require("psi.tui_components.tool_execution")

ansi.enabled = true
ansi.color_enabled = true
theme.use("pi-light")

local call = te.render_call("bash", { command = "ls -la" })
local records = require("psi.records")
local execution = te.new({tool = "edit", input = {path = "example.lua", oldText = "old", newText = "new"},
  frame = {before_text = "old"}})
local pending = table.concat(execution:render(40), "\n")
assert(pending:find("\27[48;2;232;232;240m", 1, true))
theme.use("pi-dark")
local dark = table.concat(execution:render(40), "\n")
assert(dark:find("\27[48;2;40;40;50m", 1, true))
assert(dark:find("\27[1;38;2;212;212;212m", 1, true))
assert(not dark:find("\27[38;2;31;35;40m", 1, true))
execution:set_result(records.new_tool_result(true, "edit", nil, {}), false)
assert(table.concat(execution:render(40), "\n"):find("\27[48;2;40;50;40m", 1, true))
execution:set_result(records.new_tool_result(false, "edit", "failure", {}), false)
assert(table.concat(execution:render(40), "\n"):find("\27[48;2;60;40;40m", 1, true))
execution:set_result(records.new_tool_result(true, "edit", nil, {}), true)
assert(table.concat(execution:render(40), "\n"):find("\27[48;2;40;40;50m", 1, true))
ansi.color_enabled = false
assert(not table.concat(execution:render(40), "\n"):find("\27[48;", 1, true))
ansi.color_enabled = true
theme.use("pi-light")
return table.concat({
  -- pale pending tint from pi's current light theme
  tostring(call:find("\27[48;2;232;232;240m", 1, true) ~= nil),
  -- dark title text from pi's current light theme (bold)
  tostring(call:find("\27[1;38;2;31;35;40m", 1, true) ~= nil),
  -- the raw dark-green success palette must not leak through
  tostring(call:find("\27[48;5;22m", 1, true) == nil),
}, "|")
