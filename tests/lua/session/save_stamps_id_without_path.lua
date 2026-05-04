--[==[psi-test
contains = "stamped"
]==]
local session = require("psi.session_manager")
print("before:", tostring(psi.session_id()))
session.save()
local id = psi.session_id()
return (id ~= nil and #id > 0) and "stamped" or "still-nil"
