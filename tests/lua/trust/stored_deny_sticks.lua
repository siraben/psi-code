--[==[psi-test
expect = "none|false"
cwd = "stored-deny-project"
env = { PSI_TRUST = "" }
files = [
  { path = "{TMP}/config/psi/trust.json", text = "{\"{cwd}\": false}" },
  { path = ".psi/settings.json", json = { marker = { value = "repo" } } },
]
]==]
-- A stored denial sticks even though resources exist.
local settings = require("psi.settings_manager")
return tostring(settings.get("marker.value", "none")) .. "|" .. tostring(psi.project_trusted)
