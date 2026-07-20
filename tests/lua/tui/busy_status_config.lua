--[==[psi-test
expect = "custom busy"
cwd = "busy-config-project"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { tui = { busy_labels = ["custom busy"] } } },
]
]==]
return require("psi.tui_status").pick_busy_status()
