--[[psi-test
expect = "stamped"
]]
local session = require("psi.session_manager")
session.append_user("hi")
local id = psi.session_id()
return (id ~= nil and #id > 0) and "stamped" or "still-nil"
