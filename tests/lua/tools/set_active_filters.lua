--[[psi-test
# Original asserts: parts[0] >= 3, parts[1] == 2, "read" in parts[2], "grep" in parts[2], parts[0] == parts[3].
# Refactored to fold all checks into the Lua return so a single equals comparison passes.
expect = "true|true|true|true|true"
]]
local t = require("psi.tools")
local all = #t.select_specs()
t.set_active({"read", "grep"})
local narrowed = #t.select_specs()
local active = t.get_active()
local has_read, has_grep = false, false
for _, name in ipairs(active) do
  if name == "read" then has_read = true end
  if name == "grep" then has_grep = true end
end
t.set_active(nil)
local restored = #t.select_specs()
return tostring(all >= 3) .. "|" .. tostring(narrowed == 2) .. "|"
  .. tostring(has_read) .. "|" .. tostring(has_grep) .. "|" .. tostring(all == restored)
