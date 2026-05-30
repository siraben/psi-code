--[==[psi-test
expect = "true"
]==]
local a = require("psi.providers.anthropic")
local session = {
  {
    role = "branch-summary",
    text = "branch context",
    data = psi.json_encode({ summary = "branch context" }),
  },
}
local wire = a._test.build_api_messages(session)
return tostring(wire[1] and wire[1].role == "user" and wire[1].content == "branch context")
