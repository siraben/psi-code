--[[psi-test
contains = "\u001b[38;5;118m"
]]
local ansi = require("psi.ansi")
local theme = require("psi.theme")
ansi.enabled = true
ansi.color_enabled = true
theme.use({ tui = { chrome = { fg = 118, bg = 233 } } })
return ansi.gray("x")
