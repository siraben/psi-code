--[==[psi-test
# Eight coding tools plus three goal-lifecycle tools.
expect = "11"
]==]
local r = require("psi.tools").dispatch("lua", {mode = "eval", expression = "#require(\"psi.tools\").all()"})
return r.extras.result
