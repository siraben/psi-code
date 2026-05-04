--[==[psi-test
contains = "false|nope"
]==]
local t = require("psi.tools")
local real_ran = false
t.add_before_hook(function(name, input)
  if name == "bash" then return t.cancel("nope") end
end)
local r = t.dispatch("bash", { command = "echo x" })
t.clear_hooks()
return tostring(r.ok) .. "|" .. tostring(r.error)
