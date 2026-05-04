--[[psi-test
expect = "psi coding agent|18|21"
]]
local layout = require("psi.tui_layout").geometry(80, 24)
return table.concat({layout.title, layout.transcript.h, layout.input.y}, "|")
