--[==[psi-test
expect = "none|false"
cwd = "self-trust-project"
env = { PSI_TRUST = "" }
files = [
  { path = ".psi/settings.json", json = { marker = { value = "repo" }, security = { default_project_trust = "always" } } },
]
]==]
-- Reading the fallback from project settings would let a repository
-- approve its own settings and extensions.
local settings = require("psi.settings_manager")
return tostring(settings.get("marker.value", "none")) .. "|"
  .. tostring(psi.project_trusted)
