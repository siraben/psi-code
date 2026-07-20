--[==[psi-test
expect = "default"
cwd = "trust-gated-settings"
files = [
  { path = ".psi/settings.json", json = { marker = "from-project" } },
]
]==]
-- Non-interactive boot with no stored decision: project settings must not load.
return require("psi.settings_manager").get("marker", "default")
