--[==[psi-test
expect = "true"
env = { OS = "Windows_NT", TERM = "", PSI_ANSI = "1" }
]==]
local ansi = require("psi.ansi")
ansi.enabled = true
ansi.color_enabled = true
psi.stdout_is_tty = function() return true end -- simulate a console, not a pipe
ansi.autodetect()
return tostring(ansi.red("x"):sub(1, 2) == string.char(27) .. "[")
