--[==[psi-test
expect = "supported=false|bullet=*|hrule=-|quote=| |spinner=|"
env = { LC_ALL = "", LC_CTYPE = "", LANG = "C", PSI_UNICODE = "" }
]==]
-- A C/POSIX locale can't carry multi-byte glyphs, so every symbol must
-- degrade to ASCII even though the terminal may handle ANSI perfectly.
local platform = require("psi.platform")
local glyphs = require("psi.glyphs")

glyphs.refresh()
return table.concat({
  "supported=" .. tostring(platform.unicode_supported()),
  "bullet=" .. glyphs.bullet,
  "hrule=" .. glyphs.hrule,
  "quote=" .. glyphs.quote_bar,
  "spinner=" .. glyphs.spinner[1],
}, "|")
