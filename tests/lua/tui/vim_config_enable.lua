--[==[psi-test
expect = "normal"
cwd = "vim-config"
files = [
  { path = ".psi/settings.json", json = { extensions = { vim_keybindings = { enabled = true } } } },
]
]==]
local rt = require("psi.tui_runtime")
local s = rt._debug_edit_keys("abc", 0, {{key="escape"}}, true)
return s.editor_mode
