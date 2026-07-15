--[==[psi-test
expect = "nil|nil"
]==]
local c = require("psi.slash_commands")
local bareword = c.input_completions("hello", 5, 24, false)
local unknown_arg = c.input_completions("/name foo", 9, 24, false)
return tostring(bareword) .. "|" .. tostring(unknown_arg)
