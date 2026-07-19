--[==[psi-test
expect = "sk-abc|sk-abc|pre-sk-abc-post|nil"
env = { PSI_CRED_TOKEN = "sk-abc" }
]==]
-- $VAR, ${VAR}, embedded interpolation, and an unset variable that
-- resolves to nothing.
local credential = require("psi.credential")
return table.concat({
  tostring(credential.resolve("$PSI_CRED_TOKEN")),
  tostring(credential.resolve("${PSI_CRED_TOKEN}")),
  tostring(credential.resolve("pre-${PSI_CRED_TOKEN}-post")),
  tostring(credential.resolve("$PSI_CRED_MISSING")),
}, "|")
