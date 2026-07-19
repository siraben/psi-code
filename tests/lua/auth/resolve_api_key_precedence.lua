--[==[psi-test
expect = "from-auth-file|auth-file|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json", OPENROUTER_API_KEY = "from-env" }
files = [
  { path = "{TMP}/auth.json", json = { openrouter = { type = "api_key", key = "from-auth-file" } } },
]
]==]
-- With both an auth-file entry and the env var set, the auth file wins.
local a = require("psi.auth_storage")
local key, source = a.resolve_api_key("openrouter", "OPENROUTER_API_KEY")
local present = a.has_api_key("openrouter", "OPENROUTER_API_KEY")
return tostring(key) .. "|" .. tostring(source) .. "|" .. tostring(present)
