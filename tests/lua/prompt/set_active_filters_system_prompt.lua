--[[psi-test
contains = "true|false|false"
]]
local tools = require("psi.tools")
local prompt = require("psi.prompt")
tools.set_active({"read"})
local sp = prompt.system_prompt()
tools.set_active(nil)
return tostring(sp:find("%- read:") ~= nil) .. "|"
  .. tostring(sp:find("%- bash:") ~= nil) .. "|"
  .. tostring(sp:find("%- grep:") ~= nil)
