--[==[psi-test
expect = "true|true|true|true|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
files = [
  { path = "{TMP}/auth.json", json = { anthropic = { type = "api_key", key = "secret" }, openai-codex = { type = "oauth", access = "a", refresh = "r", expires = 123 } } },
]
]==]
local commands = require("psi.slash_commands")
local auth = require("psi.auth_storage")
local selection = commands.handle("/logout").payload
local removed = commands.handle("/logout anthropic").payload
local data = auth.load()
return table.concat({
  tostring(selection:find("/logout anthropic", 1, true) ~= nil),
  tostring(selection:find("/logout openai-codex", 1, true) ~= nil),
  tostring(removed:find("Environment variables and settings are unchanged.", 1, true) ~= nil),
  tostring(data.anthropic == nil),
  tostring(data["openai-codex"] ~= nil),
}, "|")
