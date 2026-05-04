--[[psi-test
contains = ["updated", "delta"]
files = [
  { path = "tool.txt", text = "alpha beta" },
]
]]
local path = TMP .. "/tool.txt"
local tools = require('psi.tools')
local render = require('psi.render')
render.handle_event('tool-call', {id = 'w1', tool = 'write', input = {path = path, content = 'delta'}})
local r = tools.dispatch('write', {path = path, content = 'delta'})
return render.handle_event('tool-result', {id = 'w1', tool = 'write', result = r})
