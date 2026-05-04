--[==[psi-test
expect = "edit true 1|alpha gamma"
files = [
  { path = "tool.txt", text = "alpha beta" },
]
]==]
local path = TMP .. "/tool.txt"
local r = require('psi.tools').dispatch('edit', {path = path, oldText = "beta", newText = "gamma"})
return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.replacements)
  .. "|" .. (psi.read_file(path) or "<missing>")
