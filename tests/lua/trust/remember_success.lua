--[==[psi-test
expect = "true|false|true"
env = { PSI_TRUST = "always" }
]==]
local trust = require("psi.trust")
local ok = trust.remember(psi.cwd(), true)
local action = psi.commands.handle("/trust never")
return tostring(ok) .. "|" .. tostring(trust.stored(psi.cwd())) .. "|"
  .. tostring(action.payload:find("saved trust decision: untrusted", 1, true) == 1)
