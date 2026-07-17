--[==[psi-test
expect = "true|true"
]==]
local rt = require("psi.tui_runtime")

local up = rt._debug_history_sequence({}, { "arrow-up", "arrow-up" }, "hi")
local down = rt._debug_history_sequence({}, { "arrow-down" }, "hi")

return tostring(up.scrolled == true) .. "|" .. tostring(down.scrolled == true)
