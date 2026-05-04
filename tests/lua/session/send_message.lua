--[==[psi-test
contains = "2|false|unsupported role: bogus"
]==]
local s = require("psi.session_manager")
local before = psi.session_message_count()
s.send_message("user", "from extension")
s.send_message("assistant", "hi")
local ok, err = s.send_message("bogus", "x")
return psi.session_message_count() - before
  .. "|" .. tostring(ok) .. "|" .. tostring(err)
