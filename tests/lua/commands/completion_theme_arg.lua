--[==[psi-test
expect = "true|8"
]==]
local c = require("psi.slash_commands")
local r = c.input_completions("/theme pi", 9, 24, false)
local seen = {}
for _, it in ipairs(r.items) do
  seen[it.insert] = true
end
return tostring(seen["pi-dark"] and seen["pi-light"] and r.kind == "argument")
  .. "|"
  .. tostring(r.start)
