--[[psi-test
expect = "alpha|al|true"
]]
local rt = require("psi.tui_runtime")
local r = rt._debug_history_sequence({"alpha", "beta", "alphabet"}, {"ctrl-r", "text:a", "text:l", "ctrl-r"})
return r.input .. '|' .. r.history_search_query .. '|' .. tostring(r.history_search_active)
