--[[psi-test
expect = "false | no session path set"
]]
local session = require("psi.session_manager")
local ok, err = session.save()
return tostring(ok) .. " | " .. tostring(err)
