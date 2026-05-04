--[==[psi-test
expect = "true|oauth|a|acct"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
]==]
local a = require("psi.auth_storage")
local ok = a.set("openai-codex", {type="oauth", access="a", refresh="r", expires=123, accountId="acct"})
local c = a.get("openai-codex")
return tostring(ok) .. "|" .. c.type .. "|" .. c.access .. "|" .. c.accountId
