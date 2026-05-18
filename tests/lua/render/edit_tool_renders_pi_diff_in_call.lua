--[==[psi-test
expect = "true|true|true|true|true"
files = [
  { path = "edit.txt", text = "alpha beta\nomega" },
]
]==]
local ansi = require("psi.ansi")
local render = require("psi.render")
local tools = require("psi.tools")

ansi.enabled = true
ansi.color_enabled = true

local path = TMP .. "/edit.txt"
local input = {
  path = path,
  oldText = "alpha beta",
  newText = "alpha delta",
}
render.handle_event("before-turn", {})
local call = render.handle_event("tool-call", { id = "e1", tool = "edit", input = input })
local result = tools.dispatch("edit", input)
local result_text =
  render.handle_event("tool-result", { id = "e1", tool = "edit", result = result })

return table.concat({
  tostring(call:find("\27[48;2;40;50;40m", 1, true) ~= nil),
  tostring(call:find("-alpha ", 1, true) ~= nil),
  tostring(call:find("+alpha ", 1, true) ~= nil),
  tostring(call:find("\27[7m", 1, true) ~= nil),
  tostring(result_text:find("edit completed", 1, true) ~= nil),
}, "|")
