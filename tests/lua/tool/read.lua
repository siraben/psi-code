--[[psi-test
expect = "read true"
]]
local r = require("psi.tools").dispatch("read", {path="README.md"})
return r.tool .. " " .. tostring(r.ok)
