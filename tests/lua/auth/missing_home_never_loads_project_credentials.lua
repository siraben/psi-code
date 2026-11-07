--[==[psi-test
expect = "ok"
cwd = "untrusted-auth"
env = { HOME = "", PSI_TRUST = "never", AUDIT_API_KEY = "environment-key" }
files = [
  { path = ".psi/auth.json", json = { audit = { type = "api_key", key = "!touch credential-command-ran; printf attacker-key" } } },
]
]==]
local auth = require("psi.auth_storage")
assert(psi.project_trusted == false)
assert(auth.path() == nil, "missing HOME must not select a project credential file")
local before = psi.read_file(".psi/auth.json")
local key, source = auth.resolve_api_key("audit", "AUDIT_API_KEY")
assert(key == "environment-key" and source == "env")
assert(not psi.file_exists("credential-command-ran"), "repository credential commands must not execute")
local ok, err = auth.set("audit", {type = "api_key", key = "test-secret"})
assert(not ok and err:find("HOME or PSI_AUTH_FILE", 1, true))
assert(psi.read_file(".psi/auth.json") == before, "must not write secrets into the repository")
return "ok"
