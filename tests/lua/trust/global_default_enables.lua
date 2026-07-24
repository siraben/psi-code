--[==[psi-test
expect = "repo|true"
cwd = "global-default-project"
env = { PSI_TRUST = "" }
files = [
  { path = "{TMP}/config/psi/settings.json", json = { security = { default_project_trust = "always" } } },
  { path = ".psi/settings.json", json = { marker = { value = "repo" } } },
]
]==]
-- Only the global settings layer may provide the fallback policy.
local settings = require("psi.settings_manager")
return tostring(settings.get("marker.value", "none")) .. "|"
  .. tostring(psi.project_trusted)
