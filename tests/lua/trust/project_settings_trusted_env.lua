--[==[psi-test
expect = "from-project"
cwd = "trust-env-settings"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { marker = "from-project" } },
]
]==]
-- PSI_TRUST=always opts the project in without a prompt.
return require("psi.settings_manager").get("marker", "default")
