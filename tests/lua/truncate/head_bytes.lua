--[[psi-test
expect = "alpha\nbravo|true|bytes"
]]
local t = require("psi.truncate")
local body = "alpha\nbravo\ncharlie\ndelta"
local r = t.truncate_head(body, { max_bytes = 12 })
return r.content .. "|" .. tostring(r.truncated) .. "|" .. r.truncated_by
