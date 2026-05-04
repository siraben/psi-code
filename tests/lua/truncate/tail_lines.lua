--[==[psi-test
expect = "line 8\nline 9\nline 10|lines|3"
]==]
local t = require("psi.truncate")
local lines = {}
for i = 1, 10 do lines[#lines + 1] = "line " .. i end
local r = t.truncate_tail(table.concat(lines, "\n"), { max_lines = 3 })
return r.content .. "|" .. r.truncated_by .. "|" .. tostring(r.output_lines)
