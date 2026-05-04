--[[psi-test
contains = "[TAIL]"
]]
local p = require("psi.prompt")
p.register_transformer(function(s) return s .. " [TAIL]" end)
local sp = p.system_prompt()
p.clear_transformers()
return sp:sub(-6)
