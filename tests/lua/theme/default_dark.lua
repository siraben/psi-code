--[[psi-test
expect = "midnight-ember|234|81"
]]
local t = require("psi.theme")
local cur = t.current()
return t.current_name() .. "|"
  .. tostring(cur.tui.chrome.bg) .. "|"
  .. tostring(cur.tui.accent.fg)
