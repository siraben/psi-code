--[==[psi-test
expect = "set-thinking|xhigh|print|true"
]==]
local c = require("psi.slash_commands")
local a = c.handle("/thinking xhigh")
local b = c.handle("/thinking nope")
return a.kind .. "|" .. tostring(a.payload) .. "|" .. b.kind .. "|"
  .. tostring(b.payload:find("usage: /thinking", 1, true) ~= nil)
