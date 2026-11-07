--[==[psi-test
expect = "true|true|true|true"
cwd = "tool-expansion-shortcut"
files = [
  { path = ".psi/keybindings.json", json = { "app.tools.expand" = "ctrl-b" } },
]
]==]
local tool = require("psi.tui_components.tool_execution")
local records = require("psi.records")
local tui_text = require("psi.tui_text")
local lines = {}
for i = 1, 12 do
  lines[i] = "line " .. tostring(i)
end
local execution = tool.new({ tool = "bash", input = { command = "demo" } })
execution:set_result(
  records.new_tool_result(true, "bash", nil, {
    output = table.concat(lines, "\n"),
  }),
  false
)
local collapsed = tui_text.strip_ansi(table.concat(execution:render(80), "\n"))
assert(collapsed:find("2 earlier lines, ctrl+b to expand", 1, true))
assert(not collapsed:find("ctrl+o", 1, true))
-- Cached components follow changed shortcut assignments.
assert(psi.file_write(".psi/keybindings.json", '{"app.tools.expand":"ctrl-o"}'))
require("psi.keybindings").reload()
local rebound = tui_text.strip_ansi(table.concat(execution:render(80), "\n"))
assert(rebound:find("2 earlier lines, ctrl+o to expand", 1, true))
execution:set_expanded(true)
local expanded = tui_text.strip_ansi(table.concat(execution:render(80), "\n"))
assert(not expanded:find("to expand", 1, true))
return table.concat({
  tostring(collapsed:find("earlier lines", 1, true) ~= nil),
  tostring(collapsed:find(" line 1 ", 1, true) == nil),
  tostring(expanded:find(" line 1 ", 1, true) ~= nil),
  tostring(expanded:find("earlier lines", 1, true) == nil),
}, "|")
