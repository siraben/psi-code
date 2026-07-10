--[==[psi-test
expect = "false|true|true"
]==]
local r = require("psi.tools").dispatch("bash", {
  command = "sleep 2",
  timeout = 0.1,
})
local output = r.extras.output or ""
return tostring(r.ok) .. "|"
  .. tostring(r.extras.timed_out) .. "|"
  .. tostring(output:find("Command timed out after 0.1 seconds", 1, true) ~= nil)
