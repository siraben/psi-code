--[[psi-test
contains = "true|true|true|true"
]]
local r = require("psi.tools").dispatch("bash", {
  command = "yes hello | head -c 200000"
})
return tostring(r.extras.truncated) .. "|"
       .. tostring(r.extras.total_bytes >= 200000) .. "|"
       .. tostring(r.extras.output:find("Showing", 1, true) ~= nil) .. "|"
       .. tostring(#r.extras.output < 200000)
