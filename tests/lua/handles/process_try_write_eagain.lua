--[==[psi-test
expect = "partial"
]==]
local h, err = psi.process_begin_stdio_argv({ "sh", "-c", "sleep 5" })
if not h then
  return err
end
local payload = string.rep("x", 1024 * 1024)
local n = psi.process_try_write(h, payload)
psi.process_terminate(h)
psi.process_finish(h)
if n == nil then
  return "nil"
end
if n == #payload then
  return "no-backpressure"
end
return "partial"
