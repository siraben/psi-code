--[==[psi-test
expect = "* item|| quoted"
env = { LC_ALL = "", LC_CTYPE = "", LANG = "C", PSI_UNICODE = "" }
]==]
-- Markdown rendering is used by CLI output too, so its glyphs have to
-- degrade with the locale just like the TUI's do.
local ansi = require("psi.ansi")
local glyphs = require("psi.glyphs")
local markdown = require("psi.markdown")
local text = require("psi.tui_text")

ansi.enabled = false
ansi.color_enabled = false
glyphs.refresh()
markdown.clear_render_cache()

return table.concat({
  text.strip_ansi(markdown.render_line("- item", false)),
  text.strip_ansi(markdown.render_line("> quoted", false)),
}, "|")
