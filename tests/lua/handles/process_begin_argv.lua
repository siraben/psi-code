--[[psi-test
expect = "async argv|0"
]]
local h = psi.process_begin_argv({"printf", "%s", "async argv"})
while true do
  local _, done = psi.process_poll(h, 50)
  if done then break end
end
local r = psi.process_finish(h)
return r.output .. "|" .. tostring(r.status)
