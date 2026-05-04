--[==[psi-test
expect = "write true|alpha"
]==]
local path = TMP .. "/nested/child/tool.txt"
local r = require('psi.tools').dispatch('write', {path = path, content = "alpha"})
return r.tool .. ' ' .. tostring(r.ok) .. "|" .. (psi.read_file(path) or "<missing>")
