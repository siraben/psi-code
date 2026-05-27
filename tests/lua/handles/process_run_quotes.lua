--[==[psi-test
expect = "hello|0"
]==]
local r = psi.process_run('echo "hello"')
return r.output:gsub("%s+$", "") .. "|" .. tostring(r.status)
