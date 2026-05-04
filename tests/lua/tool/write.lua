--[==[psi-test
expect = "write true 10|alpha beta"
]==]
local path = TMP .. "/tool.txt"
local r = require('psi.tools').dispatch('write', {path = path, content = "alpha beta"})
return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.bytes_written)
  .. "|" .. (psi.read_file(path) or "<missing>")
