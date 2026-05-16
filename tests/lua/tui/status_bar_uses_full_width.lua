--[==[psi-test
expect = "10|L        R"
]==]
local tui = require("psi.tui_status")
local text = tui.compose_bar("L" .. string.char(31) .. "R", 10)
return tostring(require("psi.tui_text").visible_width(text)) .. "|" .. text
