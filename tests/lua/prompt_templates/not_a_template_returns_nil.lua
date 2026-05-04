--[==[psi-test
contains = "nil"
]==]
local pt = require("psi.prompt_templates")
pt.load()
return tostring(pt.expand("/nosuchtemplate foo"))
