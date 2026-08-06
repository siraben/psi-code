--[==[psi-test
expect = "supported=true|bullet=•|hrule=─"
env = { LC_ALL = "", LC_CTYPE = "", LANG = "en_US.UTF-8", PSI_UNICODE = "" }
]==]
local platform = require("psi.platform")
local glyphs = require("psi.glyphs")

glyphs.refresh()
return table.concat({
  "supported=" .. tostring(platform.unicode_supported()),
  "bullet=" .. glyphs.bullet,
  "hrule=" .. glyphs.hrule,
}, "|")
