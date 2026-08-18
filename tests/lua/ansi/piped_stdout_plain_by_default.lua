--[==[psi-test
expect = "false|false"
]==]
-- The runner pipes stdout, so autodetect must disable ANSI.
local ansi = require("psi.ansi")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return tostring(ansi.enabled) .. "|" .. tostring(ansi.color_enabled)
