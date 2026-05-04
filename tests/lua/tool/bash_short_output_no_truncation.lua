--[[psi-test
expect = "false|short"
]]
local r = require("psi.tools").dispatch("bash", {command="printf short"})
return tostring(r.extras.truncated) .. "|" .. r.extras.output
