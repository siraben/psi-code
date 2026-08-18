--[==[psi-test
expect = "true|true"
env = { PSI_ANSI = "1", PSI_COLOR = "1" }
]==]
-- Explicit force flags must win over the piped-stdout default.
local ansi = require("psi.ansi")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return tostring(ansi.enabled) .. "|" .. tostring(ansi.color_enabled)
