--[==[psi-test
expect = "secret-from-env|auth-file"
env = { PSI_AUTH_FILE = "{TMP}/auth.json", PSI_CRED_UPSTREAM = "secret-from-env" }
files = [
  { path = "{TMP}/auth.json", json = { openrouter = { type = "api_key", key = "${PSI_CRED_UPSTREAM}" } } },
]
]==]
-- An auth-file api_key entry whose value is a ${VAR} reference is
-- expanded through psi.credential before use.
local a = require("psi.auth_storage")
local key, source = a.resolve_api_key("openrouter", "OPENROUTER_API_KEY")
return tostring(key) .. "|" .. tostring(source)
