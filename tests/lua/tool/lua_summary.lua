--[==[psi-test
expect = "psi Lua runtime"
]==]
local r = require("psi.tools").dispatch("lua", {mode = "summary"})
return r.extras.result:match("psi Lua runtime")
