--[==[psi-test
expect = "7"
cwd = "tui-layout-settings"
files = [
  { path = ".psi/settings.json", json = { tui = { prompt = { max_rows = 7 } } } },
]
]==]
local layout = require("psi.tui_runtime")._debug_resolve_input_layout(80, 24)
return tostring(layout.max_rows or -1)
