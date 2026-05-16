--[==[psi-test
expect = "true|1|assistant|plain reply|false|0||"
]==]
local rt = require("psi.tui_runtime")
local added = rt._debug_nonstreamed_assistant_reply("plain reply", false)
local skipped = rt._debug_nonstreamed_assistant_reply("streamed reply", true)
return added .. "|" .. skipped
