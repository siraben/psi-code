--[==[psi-test
expect = "parallel|parallel"
]==]
local tools = require("psi.tools")
return tools.find("edit").execution_mode .. "|" .. tools.find("write").execution_mode
