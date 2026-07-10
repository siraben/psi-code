--[==[psi-test
expect = "print|true|true|set-theme|pi-light"
]==]
-- /theme with no argument lists the registered themes; with a name it
-- emits a set-theme action the TUI runtime applies.
local c = require("psi.slash_commands")
local theme = require("psi.theme")
theme.bootstrap()

local list = c.handle("/theme")
local switch = c.handle("/theme pi-light")
return table.concat({
  list.kind,
  tostring(list.payload:find("pi-dark", 1, true) ~= nil),
  tostring(list.payload:find("pi-light", 1, true) ~= nil),
  switch.kind,
  tostring(switch.payload),
}, "|")
