--[==[psi-test
expect = "pi-dark|234|115"
]==]
local t = require("psi.theme")
local cur = t.current()
return t.current_name() .. "|"
  .. tostring(cur.tui.chrome.bg) .. "|"
  .. tostring(cur.tui.accent.fg)
