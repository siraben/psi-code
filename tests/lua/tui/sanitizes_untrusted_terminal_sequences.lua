--[==[psi-test
expect = "abredc\nnext"
]==]
local rt = require("psi.tui_runtime")
local esc = string.char(27)
local bel = string.char(7)
local input = "a" .. esc .. "]52;c;evil" .. bel .. "b" .. esc .. "[31mred" .. esc .. "[0mc\nnext"
return rt._debug_sanitize_terminal_text(input, true)
