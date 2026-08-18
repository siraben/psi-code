--[==[psi-test
expect = "false|3|true"
]==]
-- pi-mono parity: a tool child that dies (here: closes the pipe, then
-- exits non-zero) must make the tool call return with the exit status
-- surfaced, not hang the turn.
local r = require("psi.tools").dispatch("bash", {
  command = "exec 1>&- 2>&-; sleep 0.2; exit 3",
})
local output = r.extras.output or ""
return tostring(r.ok)
  .. "|"
  .. tostring(r.extras.status)
  .. "|"
  .. tostring(output:find("Command exited with code 3", 1, true) ~= nil)
