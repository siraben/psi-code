--[==[psi-test
expect = "true|true|true|true"
]==]
local ansi = require("psi.ansi")
local render = require("psi.render")
local text = require("psi.tui_text")

ansi.enabled = true
ansi.color_enabled = true

render.handle_event("before-turn", {})
local call = render.handle_event("tool-call", {
  id = "box-read",
  tool = "read",
  input = { path = "README.md" },
})
local result = render.handle_event("tool-result", {
  id = "box-read",
  tool = "read",
  result = { ok = true, text = "alpha\nbeta" },
})

local call_plain = text.strip_ansi(call)
local result_plain = text.strip_ansi(result)
local first = call_plain:match("\n([^\n]*)") or call_plain:match("([^\n]*)") or ""

return table.concat({
  tostring(call_plain:find("\n read README.md", 1, true) ~= nil),
  tostring(text.visible_width(first) == 80),
  tostring(result_plain:find(" alpha", 1, true) ~= nil),
  tostring(result_plain:sub(-1) == "\n"),
}, "|")
