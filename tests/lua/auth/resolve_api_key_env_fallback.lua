--[==[psi-test
expect = "from-env|env|true|nil|false"
env = { PSI_AUTH_FILE = "{TMP}/auth.json", OPENROUTER_API_KEY = "from-env" }
]==]
-- No auth file on disk: fall back to the environment variable. A
-- provider with neither entry nor env var resolves to nothing.
local a = require("psi.auth_storage")
local key, source = a.resolve_api_key("openrouter", "OPENROUTER_API_KEY")
local present = a.has_api_key("openrouter", "OPENROUTER_API_KEY")
local none_key = a.resolve_api_key("anthropic", "PSI_UNSET_KEY_ENV")
local none_present = a.has_api_key("anthropic", "PSI_UNSET_KEY_ENV")
return table.concat({
  tostring(key), tostring(source), tostring(present),
  tostring(none_key), tostring(none_present),
}, "|")
