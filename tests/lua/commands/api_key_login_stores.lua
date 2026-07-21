--[==[psi-test
expect = "print|api_key|stored-secret|true|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
]==]
local commands = require("psi.slash_commands")
local auth = require("psi.auth_storage")
local action = commands.handle("/login anthropic stored-secret")
local entry = auth.get("anthropic")
return table.concat({
  action.kind,
  entry.type,
  entry.key,
  tostring(action.payload:find("Saved API key for Anthropic", 1, true) ~= nil),
  tostring(action.payload:find("stored-secret", 1, true) == nil),
}, "|")
