--[[psi-test
expect = "true|"
]]
local t = require("psi.truncate")
local body = string.rep("x", 200) .. "\nshort"
local r = t.truncate_head(body, { max_bytes = 50 })
return tostring(r.first_line_exceeds_limit) .. "|"
       .. (r.content or "<nil>")
