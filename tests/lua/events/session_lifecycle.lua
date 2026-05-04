--[[psi-test
contains = "start:new,shutdown"
]]
local seen = {}
psi.events.on("session-start", function(p)
  seen[#seen + 1] = "start:" .. tostring(p.source)
end)
psi.events.on("session-shutdown", function()
  seen[#seen + 1] = "shutdown"
end)
local s = require("psi.session_manager")
s.announce_start()
s.announce_shutdown()
return table.concat(seen, ",")
