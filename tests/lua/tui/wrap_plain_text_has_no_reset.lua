--[==[psi-test
expect = "true"
env = { PSI_ANSI = "0" }
]==]
local tool = require("psi.tui_components.tool_execution")
local out = tool.render_call("read", { path = string.rep("a", 120) }, nil)
return tostring(out:find("\27[0m", 1, true) == nil)
