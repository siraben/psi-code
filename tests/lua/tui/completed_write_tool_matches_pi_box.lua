--[==[psi-test
expect = "true|true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local text = require("psi.tui_text")
local rt = require("psi.tui_runtime")

ansi.enabled = true
ansi.color_enabled = true

local out = rt._debug_completed_write_tool_block()
local plain = text.strip_ansi(out)
local first = plain:match("([^\n]*)") or ""
return table.concat({
  tostring(out:find("\27[48;2;40;50;40m", 1, true) ~= nil),
  tostring(out:find("\27[48;2;40;40;50m", 1, true) == nil),
  tostring(text.visible_width(first) == 80),
  tostring(plain:find("alpha", 1, true) ~= nil),
  tostring(plain:find("beta", 1, true) ~= nil),
  tostring(plain:find("wrote notes.txt", 1, true) == nil),
}, "|")
