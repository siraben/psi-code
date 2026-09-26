--[==[psi-test
expect = "supported=false"
env = { LC_ALL = "C", LC_CTYPE = "en_US.UTF-8", LANG = "en_US.UTF-8", PSI_UNICODE = "" }
]==]
-- POSIX precedence: LC_ALL outranks LC_CTYPE and LANG even when they disagree.
local platform = require("psi.platform")
return "supported=" .. tostring(platform.unicode_supported())
