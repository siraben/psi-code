--[[psi-test
expect = "ansi-print|true|true"
env = { NO_COLOR = "1", PSI_COLOR = "0" }
]]
local action = require("psi.slash_commands").handle("/rainbow")
local payload = action.payload or ""
return table.concat({
  action.kind,
  tostring(payload:find("48;5;0", 1, true) ~= nil),
  tostring(payload:find("48;5;255", 1, true) ~= nil)
}, "|")
