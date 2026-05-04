--[[psi-test
expect = "extension-picked|118"
cwd = "theme-extension-selected-project"
env = { PSI_EXTENSIONS_DIR = "{TMP}/theme-extension-selected-ext" }
files = [
  { path = "{TMP}/theme-extension-selected-project/.psi", mkdir = true },
  { path = "{TMP}/theme-extension-selected-ext/select.lua", text = "return function(psi)\n  psi.theme.register('extension-picked', {\n    tui = { accent = { fg = 118, bg = 233 } },\n  })\n  assert(psi.theme.use('extension-picked'))\nend\n" },
]
]]
local t = require("psi.theme")
local cur = t.current()
return t.current_name() .. "|" .. tostring(cur.tui.accent.fg)
