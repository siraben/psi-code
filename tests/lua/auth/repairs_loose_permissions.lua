--[==[psi-test
expect = "600"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
files = [
  { path = "auth.json", text = "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"k\"}}" },
]
]==]
-- Fixtures are written 0644 by the harness; a read must repair to 0600.
local a = require("psi.auth_storage")
a.load()
local r = psi.process_run_argv({ "stat", "-c", "%a", os.getenv("PSI_AUTH_FILE") })
return (r.output or ""):gsub("%s+", "")
