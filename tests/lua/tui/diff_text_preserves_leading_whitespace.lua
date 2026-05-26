--[==[psi-test
expect = "true|true|true"
]==]
local component = require("psi.tui_component")
local diff = require("psi.tui_components.diff")
local tui_text = require("psi.tui_text")

local rendered = diff.render_diff("-1   foo\n+1     bar")
local lines = component.text(rendered, 0, 0, nil, { preserve_whitespace = true }):render(80)
local out = tui_text.strip_ansi(table.concat(lines, "\n"))

return table.concat({
  tostring(out:find("-1   foo", 1, true) ~= nil),
  tostring(out:find("+1     bar", 1, true) ~= nil),
  tostring(out:find("-1 foo", 1, true) == nil),
}, "|")
