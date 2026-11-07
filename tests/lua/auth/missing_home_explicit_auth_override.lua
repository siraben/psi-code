--[==[psi-test
expect = "ok"
env = { HOME = "", PSI_AUTH_FILE = "{TMP}/explicit-auth.json" }
]==]
local auth = require("psi.auth_storage")
assert(auth.path() == TMP .. "/explicit-auth.json")
assert(auth.set("audit", {type = "api_key", key = "explicit-key"}))
local key, source = auth.resolve_api_key("audit", nil)
assert(key == "explicit-key" and source == "auth-file")
return "ok"
