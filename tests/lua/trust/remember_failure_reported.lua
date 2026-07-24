--[==[psi-test
expect = "false|true"
env = { PSI_TRUST = "always", XDG_CONFIG_HOME = "{TMP}/blocked" }
files = [
  { path = "{TMP}/blocked", text = "not a directory" },
]
]==]
-- A failed durable write must be reported instead of claiming that
-- the decision was saved.
local trust = require("psi.trust")
local ok = trust.remember(psi.cwd(), true)
local action = psi.commands.handle("/trust always")
return tostring(ok) .. "|"
  .. tostring(action.payload:find("could not save trust decision:", 1, true) == 1)
