--[==[psi-test
expect = "tree|abc123|true|focus words"
]==]
local c = require("psi.slash_commands")
local action = c.handle("/tree abc123 --summarize focus words")
return action.kind
  .. "|"
  .. action.payload.target
  .. "|"
  .. tostring(action.payload.summarize)
  .. "|"
  .. action.payload.custom_instructions
