--[==[psi-test
expect = "high|none|medium"
]==]
local a = require("psi.agent_session")
a.set_reasoning_effort("high")
local got = a.current_reasoning_effort("low")
a.set_reasoning_effort("none")
local none = a.current_reasoning_effort("low")
a.set_reasoning_effort(nil)
local cleared = a.current_reasoning_effort("medium")
return got .. "|" .. none .. "|" .. cleared
