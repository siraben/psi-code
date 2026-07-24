--[==[psi-test
expect = "repo|true"
cwd = "stored-project"
env = { PSI_TRUST = "" }
files = [
  { path = "{TMP}/config/psi/trust.json", text = "{\"{cwd}\": true}" },
  { path = ".psi/settings.json", json = { marker = { value = "repo" } } },
]
]==]
-- A stored trust decision enables project resources.
local settings = require("psi.settings_manager")
return tostring(settings.get("marker.value", "none")) .. "|" .. tostring(psi.project_trusted)
