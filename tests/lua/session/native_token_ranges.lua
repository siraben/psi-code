--[==[psi-test
# Psi's calibrated pi-style heuristic: full == 9, tail == 4, keep == 1.
expect = "9|4|1"
]==]
local s = require("psi.session_manager")
local c = require("psi.context")
s.append_user("12345678")
s.append_user("1234")
s.append_user("123456789")
local full = psi.session_token_estimate_from(1)
local tail = psi.session_token_estimate_from(3)
local keep = c.keep_recent_messages(tail)
return tostring(full) .. "|" .. tostring(tail) .. "|" .. tostring(keep)
