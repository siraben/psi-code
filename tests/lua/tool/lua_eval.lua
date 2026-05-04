--[==[psi-test
# Eight tools registered today (read/write/edit/bash/grep/find/ls/lua).
expect = "8"
]==]
local r = require("psi.tools").dispatch("lua", {mode = "eval", expression = "#require(\"psi.tools\").all()"})
return r.extras.result
