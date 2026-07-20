--[==[psi-test
expect = "true"
env = { HOME = "{TMP}/cb-home" }
files = [
  { path = "cb-home/.config/psi/settings.json", json = { extensions = { osc52_clipboard = { target = "c\u0007;evil" } } } },
]
]==]
-- A configured OSC 52 target carrying control bytes must be rejected in
-- favour of the default "c" so settings cannot break out of the sequence.
local seq = require("psi.clipboard").osc52_sequence("hi")
return tostring(seq:find("]52;c;", 1, true) ~= nil)
