--[==[psi-test
expect = "1"
cwd = "thinking-config-project"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { tui = { show_thinking = true } } },
]
]==]
return require("psi.tui_status").show_thinking()
