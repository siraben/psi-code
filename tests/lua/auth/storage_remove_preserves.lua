--[==[psi-test
expect = "true|api_key|oauth|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
files = [
  { path = "{TMP}/auth.json", json = { anthropic = { type = "api_key", key = "secret" }, openai-codex = { type = "oauth", access = "a", refresh = "r", expires = 123 } } },
]
]==]
local auth = require("psi.auth_storage")
local ok, removed = auth.remove("anthropic")
local data = auth.load()
return table.concat({
  tostring(ok),
  removed.type,
  data["openai-codex"].type,
  tostring(data.anthropic == nil),
}, "|")
