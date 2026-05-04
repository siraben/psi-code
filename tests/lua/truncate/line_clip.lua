--[==[psi-test
expect = "true|... [truncated]"
]==]
local t = require("psi.truncate")
local clipped, was = t.truncate_line(string.rep("a", 600), 100)
return tostring(was) .. "|" .. clipped:sub(101, 116)
