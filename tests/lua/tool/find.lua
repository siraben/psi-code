--[==[psi-test
expect = "find true true"
]==]
local r = require("psi.tools").dispatch("find", {pattern = "*.md", path = ".", limit = 5})
return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)
