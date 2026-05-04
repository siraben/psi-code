--[[psi-test
expect = "toxic|118|233|253"
cwd = "theme-project"
env = { PSI_EXTENSIONS_DIR = "{TMP}/theme-ext" }
files = [
  { path = "{TMP}/theme-project/.psi/settings.json", json = { theme = { name = "toxic" } } },
  { path = "{TMP}/theme-ext/toxic.lua", text = "return function(psi)\n  psi.theme.register('toxic', {\n    tui = {\n      accent = { fg = 118, bg = 233 },\n      chrome = { fg = 244, bg = 233 },\n    },\n  })\nend\n" },
]
]]
local t = require("psi.theme")
local cur = t.current()
return t.current_name() .. "|"
  .. tostring(cur.tui.accent.fg) .. "|"
  .. tostring(cur.tui.chrome.bg) .. "|"
  .. tostring(cur.tui.text.fg)
