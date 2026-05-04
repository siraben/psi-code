--[[psi-test
expect = "1"
cwd = "thinking-config-project"
files = [
  { path = ".psi/settings.json", json = { tui = { show_thinking = true } } },
]
]]
return require("psi.tui_status").show_thinking()
