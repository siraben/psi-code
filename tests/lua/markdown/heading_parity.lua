--[==[psi-test
expect = "One|Two|### Three code after|true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local markdown = require("psi.markdown")
local text = require("psi.tui_text")

ansi.enabled = true
ansi.color_enabled = true
ansi.set_code_map({})
markdown.clear_render_cache()

local h1 = markdown.render_line("# One", false)
local h2 = markdown.render_line("## Two", false)
local h3 = markdown.render_line("### Three `code` after", false)
local restore = "\27[0m\27[33m\27[1m"

return table.concat({
  text.strip_ansi(h1),
  text.strip_ansi(h2),
  text.strip_ansi(h3),
  tostring(h1:find("\27[33m", 1, true) ~= nil),
  tostring(h1:find("\27[1m", 1, true) ~= nil),
  tostring(h1:find("\27[4m", 1, true) ~= nil),
  tostring(h2:find("\27[4m", 1, true) == nil),
  tostring(h3:find(restore .. " after", 1, true) ~= nil),
}, "|")
