--[==[psi-test
expect = "true|true|true|true"
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
execution:set_expanded(true)
local expanded = tui_text.strip_ansi(table.concat(execution:render(80), "\n"))
return table.concat({
  tostring(collapsed:find("earlier lines", 1, true) ~= nil),
  tostring(collapsed:find(" line 1 ", 1, true) == nil),
  tostring(expanded:find(" line 1 ", 1, true) ~= nil),
  tostring(expanded:find("earlier lines", 1, true) == nil),
}, "|")
