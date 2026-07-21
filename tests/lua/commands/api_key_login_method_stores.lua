--[==[psi-test
expect = "api_key|$OPENROUTER_API_KEY|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
]==]
local commands = require("psi.slash_commands")
local auth = require("psi.auth_storage")
local action = commands.handle("/login api-key openrouter $OPENROUTER_API_KEY")
local entry = auth.get("openrouter")
return table.concat({
  entry.type,
  entry.key,
  tostring(action.payload:find("$OPENROUTER_API_KEY", 1, true) == nil),
}, "|")
