--[==[psi-test
expect = "0"
cwd = "thinking-pi-config-project"
files = [
  { path = ".psi/settings.json", json = { hideThinkingBlock = true } },
]
]==]
return require("psi.tui_status").show_thinking()
