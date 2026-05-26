--[==[psi-test
expect = "true|true|true"
files = [
  { path = "edit.txt", text = "   foo\nomega" },
]
]==]
local render = require("psi.render")
local tui_text = require("psi.tui_text")

local path = TMP .. "/edit.txt"
local input = {
  path = path,
  oldText = "   foo",
  newText = "     bar",
}
render.handle_event("before-turn", {})
local call = render.handle_event("tool-call", { id = "e1", tool = "edit", input = input })
local out = tui_text.strip_ansi(call)

return table.concat({
  tostring(out:find("-1    foo", 1, true) ~= nil),
  tostring(out:find("+1      bar", 1, true) ~= nil),
  tostring(out:find("-1 foo", 1, true) == nil),
}, "|")
