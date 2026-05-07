--[==[psi-test
expect = "true"
]==]
local ansi = require("psi.ansi")
local tui = require("psi.tui_status")
ansi.enabled = true
ansi.color_enabled = true
local out = tui.compose_bar(ansi.red("abcdef"), 3)
return tostring(out:sub(-4) == "\27[0m")
