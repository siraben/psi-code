--[==[psi-test
expect = "base  |aaXXaa|bbYYbb|tail  |true"
]==]
local app_mod = require("psi.tui_app")
local component = require("psi.tui_component")

local app = app_mod.new()
app:add_child(component.block({ "base", "aaaaaa", "bbbbbb", "tail" }, { pad = true }))
app:show_overlay(component.block({ "XX", "YY" }, { pad = true }), {
  width = 2,
  row = 1,
  col = 2,
  non_capturing = true,
})

local lines = app:render(6, 4)
return table.concat({
  lines[1],
  lines[2],
  lines[3],
  lines[4],
  tostring(app:has_overlay()),
}, "|")
