--[==[psi-test
expect = "+---+---+|| a | b ||+---+---+|| 1 | 2 ||+---+---+"
env = { LC_ALL = "", LC_CTYPE = "", LANG = "C", PSI_UNICODE = "" }
]==]
-- Tables draw their own borders rather than going through psi.markdown, so
-- they need the same charset fallback the rest of the chrome gets.
local ansi = require("psi.ansi")
local glyphs = require("psi.glyphs")
local Markdown = require("psi.tui_components.markdown")

ansi.enabled = false
ansi.color_enabled = false
glyphs.refresh()

local lines = Markdown.render_table({ "| a | b |", "| --- | --- |", "| 1 | 2 |" }, 40)
local out = {}
for _, line in ipairs(lines or {}) do
  out[#out + 1] = line
end
return table.concat(out, "|")
