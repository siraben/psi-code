--[==[psi-test
expect = "true|true|true"
cwd = "osc52-project"
files = [
  { path = "{TMP}/config/psi/trust.json", text = "{\"{cwd}\": true}" },
  { path = ".psi/settings.json", text = "{\"extensions\":{\"osc52_clipboard\":{\"target\":\"p\\u0007\\u001b[2J\"}}}" },
]
]==]
-- The OSC 52 target is interpolated into an escape sequence, so the
-- settings value must be stripped to alphanumerics.
local clipboard = require("psi.clipboard")
local seq = clipboard.osc52_sequence("hi", { TMUX = "" })
local stripped = seq:gsub("[\27\7]", "")
return tostring(seq:find("]52;p2J;aGk=", 1, true) ~= nil)
  .. "|" .. tostring(stripped:find("[%c]") == nil)
  .. "|" .. tostring(seq:sub(-1) == "\7")
