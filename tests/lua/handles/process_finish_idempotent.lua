--[==[psi-test
expect = "idempotent-test|0|"
]==]
local h = psi.process_begin("echo idempotent-test")
while true do
  local _, done = psi.process_poll(h, 50)
  if done then break end
end
local r1 = psi.process_finish(h)
local r2 = psi.process_finish(h)
return r1.output:gsub("%s+$", "") .. "|"
     .. tostring(r1.status) .. "|" .. r2.output
