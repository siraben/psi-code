--[==[psi-test
expect = "repo|true"
cwd = "ancestor-project/nested/deeper"
env = { PSI_TRUST = "" }
files = [
  { path = "{TMP}/config/psi/trust.json", text = "{\"{TMP}/ancestor-project\": true}" },
  { path = ".psi/settings.json", json = { marker = { value = "repo" } } },
]
]==]
-- Trust is inherited from the nearest ancestor with a stored decision.
local settings = require("psi.settings_manager")
return tostring(settings.get("marker.value", "none")) .. "|" .. tostring(psi.project_trusted)
