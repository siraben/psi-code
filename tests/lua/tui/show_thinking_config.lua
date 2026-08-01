--[==[psi-test
expect = "0"
cwd = "thinking-config-project"
files = [
  { path = ".psi/settings.json", json = { tui = { show_thinking = false } } },
]
]==]
return require("psi.tui_status").show_thinking()
