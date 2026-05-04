--[[psi-test
contains = "... [truncated]"
]]
-- Build a 2 KB line containing "needle" so grep clips its match line.
local path = TMP .. "/long.txt"
local body = string.rep("a", 1000) .. " needle " .. string.rep("b", 1000) .. "\n"
psi.file_write(path, body)
local r = require("psi.tools").dispatch("grep", {pattern = "needle", path = path})
return r.extras.output
