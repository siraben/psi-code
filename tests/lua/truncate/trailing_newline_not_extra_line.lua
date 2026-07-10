--[==[psi-test
expect = "2|2|false"
]==]
local t = require("psi.truncate")
local r = t.truncate_head("one\ntwo\n", { max_lines = 2 })
return tostring(r.total_lines) .. "|"
  .. tostring(r.output_lines) .. "|"
  .. tostring(r.truncated)
