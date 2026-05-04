--[==[psi-test
expect = "ls true true|.dot\na.txt\nsub/"
files = [
  { path = "ls/.dot", text = "" },
  { path = "ls/a.txt", text = "" },
  { path = "ls/sub", mkdir = true },
]
]==]
local r = require("psi.tools").dispatch("ls", {path = TMP .. "/ls", limit = 5})
return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)
  .. "|" .. r.extras.output
