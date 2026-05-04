--[==[psi-test
expect = "line 1\nline 2\nline 3|true|lines|3|10"
]==]
local t = require("psi.truncate")
local lines = {}
for i = 1, 10 do lines[#lines + 1] = "line " .. i end
local r = t.truncate_head(table.concat(lines, "\n"), { max_lines = 3 })
return r.content .. "|" .. tostring(r.truncated) .. "|"
       .. r.truncated_by .. "|" .. tostring(r.output_lines)
       .. "|" .. tostring(r.total_lines)
