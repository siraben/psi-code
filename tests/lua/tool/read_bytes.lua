--[==[psi-test
expect = "true|true|4"
]==]
local f = assert(io.open(TMP .. "/bytes.bin", "wb"))
f:write("MZ\0A\0B")
f:close()
local r = require("psi.tools").dispatch(
  "read",
  { path = TMP .. "/bytes.bin", mode = "bytes", offset = 0, limit = 4 }
)
return tostring(r.ok)
  .. "|"
  .. tostring((r.extras.text or ""):find("4D 5A 00 41", 1, true) ~= nil)
  .. "|"
  .. tostring(r.extras.limit)
