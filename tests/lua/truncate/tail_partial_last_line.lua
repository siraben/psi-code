--[[psi-test
# Original: parts[0] == "true", int(parts[1]) <= 50. Folded.
expect = "true|true"
]]
local t = require("psi.truncate")
local body = "head\n" .. string.rep("y", 200)
local r = t.truncate_tail(body, { max_bytes = 50, max_lines = 100 })
return tostring(r.last_line_partial) .. "|" .. tostring(#r.content <= 50)
