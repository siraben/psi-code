--[==[psi-test
expect = "hello"
]==]
local r = require("psi.tools").dispatch("bash", {command = "printf hello"})
return r.extras.output
