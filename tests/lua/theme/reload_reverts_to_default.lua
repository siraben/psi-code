--[[psi-test
expect = "midnight-ember|233|234"
cwd = "theme-reload-project"
env = { PSI_EXTENSIONS_DIR = "{TMP}/theme-reload-ext" }
files = [
  { path = "{TMP}/theme-reload-project/.psi/settings.json", json = { theme = { name = "toxic" } } },
  { path = "{TMP}/theme-reload-ext/toxic.lua", text = "return function(psi)\n  psi.theme.register('toxic', {\n    tui = { chrome = { fg = 244, bg = 233 } },\n  })\nend\n" },
]
]]
local theme = require("psi.theme")
local settings = require("psi.settings_manager")
local before = theme.current()
psi.file_write(".psi/settings.json", "{}")
settings.reload()
theme.apply_configured()
local after = theme.current()
return table.concat({
  theme.current_name(),
  tostring(before.tui.chrome.bg),
  tostring(after.tui.chrome.bg)
}, "|")
