--[==[psi-test
expect = "false||true|reply"
]==]
local rt = require("psi.tui_runtime")
local a = rt._debug_after_turn_payload("", false)
local b = rt._debug_after_turn_payload("reply", true)
return tostring(a["assistant-streamed"]) .. "|" .. a.text .. "|"
  .. tostring(b["assistant-streamed"]) .. "|" .. b.text
