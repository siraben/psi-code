--[==[psi-test
expect = "live response"
]==]
local rt = require("psi.tui_runtime")
return rt._debug_streaming_assistant_rendered({ "live ", "response" })
