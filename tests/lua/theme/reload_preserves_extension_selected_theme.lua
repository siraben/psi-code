--[==[psi-test
expect = "reload-picked|118"
cwd = "theme-command-reload-project"
env = { PSI_EXTENSIONS_DIR = "{TMP}/theme-command-reload-ext" }
files = [
  { path = "{TMP}/theme-command-reload-project/.psi", mkdir = true },
  { path = "{TMP}/theme-command-reload-ext/select.lua", text = "return function(psi)\n  psi.theme.register('reload-picked', {\n    tui = { accent = { fg = 118, bg = 233 } },\n  })\n  assert(psi.theme.use('reload-picked'))\nend\n" },
]
]==]
local commands = require("psi.slash_commands")
local theme = require("psi.theme")
commands.handle("/reload")
local cur = theme.current()
return theme.current_name() .. "|" .. tostring(cur.tui.accent.fg)
