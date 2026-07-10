--[==[psi-test
expect = "[Showing lines 2-3 of 4. Use offset=4 to continue.]\ntwo\nthree|2|4"
files = [
  { path = "read-offset.txt", text = "one\ntwo\nthree\nfour\n" },
]
]==]
local r = require("psi.tools").dispatch("read", {
  path = TMP .. "/read-offset.txt",
  offset = 2,
  limit = 2,
})
return (r.extras.text or "") .. "|"
  .. tostring(r.extras.offset) .. "|"
  .. tostring(r.extras.next_offset)
