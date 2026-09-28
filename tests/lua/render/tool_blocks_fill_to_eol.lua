--[==[psi-test
expect = "true|true"
]==]
local ansi = require("psi.ansi")
local render = require("psi.render")
local text = require("psi.tui_text")

ansi.enabled = true
ansi.color_enabled = true

local out = render.render_tool_call({
  id = "toolu_fill",
  tool = "read",
  input = { path = "README.md" },
})
local plain = text.strip_ansi(out)
local first = plain:match("\n([^\n]*)") or plain:match("([^\n]*)") or ""

return tostring(out:find("\27[48;2;40;40;50m", 1, true) ~= nil) .. "|"
  .. tostring(text.visible_width(first) == 80)
