--[==[psi-test
expect = "true|true|true|true|true|true"
]==]
local component = require("psi.tui_component")

local block = component.block({ "alpha" }, { pad = true })
local root = component.container({ block })

local first = root:render(8)
local second = root:render(8)
block:set_lines({ "alpha" })
local third = root:render(8)
block:set_lines({ "beta" })
local fourth = root:render(8)

local nested_block = component.block({ "one" }, { pad = true })
local nested = component.container({ nested_block })
local outer = component.container({ nested })
outer:render(8)
nested_block:set_lines({ "two" })
local nested_changed = outer:render(8)

return table.concat({
  tostring(first == second),
  tostring(second == third),
  tostring(fourth ~= third),
  tostring(fourth[1] == "beta    "),
  tostring(root:render(8) == fourth),
  tostring(nested_changed[1] == "two     "),
}, "|")
