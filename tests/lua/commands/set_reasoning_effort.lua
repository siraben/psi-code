--[==[psi-test
contains = "set-reasoning-effort|xhigh|print|usage: /set effort"
]==]
local c = require("psi.slash_commands")
local a = c.handle("/set effort xhigh")
local b = c.handle("/set reasoning_effort nope")
return a.kind .. "|" .. tostring(a.payload) .. "|" .. b.kind .. "|" .. b.payload
