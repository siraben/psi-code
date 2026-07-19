--[==[psi-test
expect = "true|false"
env = { PSI_AUTH_FILE = "{TMP}/auth.json", ANTHROPIC_API_KEY = "" }
files = [
  { path = "{TMP}/auth.json", json = { openrouter = { type = "api_key", key = "sk-or-from-file" } } },
]
]==]
-- OpenRouter reports authenticated purely from the auth file, with no
-- OPENROUTER_API_KEY in the environment. Anthropic (no entry, no env)
-- stays unauthenticated.
local openrouter = require("psi.providers.openrouter")
local anthropic = require("psi.providers.anthropic")
return tostring(openrouter.has_auth()) .. "|" .. tostring(anthropic.has_auth())
