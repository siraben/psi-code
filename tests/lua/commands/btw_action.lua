--[[psi-test
expect = "btw|should not call the network"
]]
local c = require("psi.slash_commands")
local action = c.handle("/btw should not call the network")
return action.kind .. "|" .. action.payload
