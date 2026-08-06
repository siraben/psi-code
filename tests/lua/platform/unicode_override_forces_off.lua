--[==[psi-test
expect = "supported=false"
env = { LC_ALL = "", LC_CTYPE = "", LANG = "en_US.UTF-8", PSI_UNICODE = "0" }
]==]
-- PSI_UNICODE wins over a perfectly good UTF-8 locale, for terminals whose
-- font lacks the glyphs even though the charset is fine.
local platform = require("psi.platform")
return "supported=" .. tostring(platform.unicode_supported())
