--[[psi-test
expect = "ok"
]]
do
  local h = psi.process_begin("true")
  psi.sleep_ms(50)
  h = nil
end
collectgarbage("collect")
collectgarbage("collect")
return "ok"
