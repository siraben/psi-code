--[[psi-test
expect = "true|false|true"
]]
-- Generate 700 long matching lines so grep head-truncates and keeps the first batch.
local path = TMP .. "/many-long-grep-lines.txt"
local f = io.open(path, "w")
for i = 0, 699 do
  f:write(string.format("a%04d needle %s\n", i, string.rep("x", 600)))
end
f:close()
local r = require("psi.tools").dispatch("grep", {pattern = "needle", path = path, limit = 700})
local o = r.extras.output or ""
return tostring(o:find("a0000", 1, true) ~= nil) .. "|"
  .. tostring(o:find("a0699", 1, true) ~= nil) .. "|"
  .. tostring(r.extras.truncated)
