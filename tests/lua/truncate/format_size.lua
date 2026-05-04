--[==[psi-test
expect = "0B|2.0KB|3.0MB"
]==]
local t = require("psi.truncate")
return t.format_size(0) .. "|" .. t.format_size(2048) .. "|"
       .. t.format_size(1024 * 1024 * 3)
