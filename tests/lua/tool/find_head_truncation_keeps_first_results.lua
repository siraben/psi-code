--[==[psi-test
expect = "true|false|true"
]==]
-- Create 700 sibling files with long names; find should head-truncate.
local root = TMP .. "/many-long-find-names"
psi.mkdir_p(root)
for i = 0, 699 do
  psi.file_write(string.format("%s/a%04d_%s", root, i, string.rep("x", 120)), "")
end
local r = require("psi.tools").dispatch("find", {pattern = "*", path = root, limit = 700})
local o = r.extras.output or ""
return tostring(o:find("a0000_", 1, true) ~= nil) .. "|"
  .. tostring(o:find("a0699_", 1, true) ~= nil) .. "|"
  .. tostring(r.extras.truncated)
