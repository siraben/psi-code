--[==[psi-test
expect = "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0|abc|xyz"
]==]
local d = require("psi.providers.oauth_openai_codex")._debug
local digest = d.base64url_encode(d.sha256_bytes("abc"))
local q = d.parse_query("http://localhost:1455/auth/callback?code=abc&state=xyz")
return digest .. "|" .. q.code .. "|" .. q.state
