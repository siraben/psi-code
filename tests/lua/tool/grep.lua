--[[psi-test
expect = "grep true"
files = [
  { path = "tool.txt", text = "alpha gamma" },
]
]]
local r = require('psi.tools').dispatch('grep', {pattern = "alpha gamma", path = TMP .. "/tool.txt", literal = true})
return r.tool .. ' ' .. tostring(r.ok)
