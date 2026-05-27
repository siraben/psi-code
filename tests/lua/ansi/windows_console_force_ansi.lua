--[==[psi-test
expect = "true"
env = { OS = "Windows_NT", TERM = "", PSI_ANSI = "1" }
]==]
local ansi = require("psi.ansi")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return tostring(ansi.red("x"):sub(1, 2) == string.char(27) .. "[")
