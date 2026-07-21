--[==[psi-test
expect = "false|true|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
files = [
  { path = "{TMP}/auth.json", text = "{not-json" },
]
]==]
local auth = require("psi.auth_storage")
local ok, err = auth.set("anthropic", { type = "api_key", key = "secret" })
local unchanged = psi.read_file(TMP .. "/auth.json") == "{not-json"
return table.concat({
  tostring(ok),
  tostring(tostring(err):find("leaving it unchanged", 1, true) ~= nil),
  tostring(unchanged),
}, "|")
