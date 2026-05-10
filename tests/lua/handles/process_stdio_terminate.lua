--[==[psi-test
expect = "130"
]==]
local h, err = psi.process_begin_stdio_argv({ "sh", "-c", "sleep 60" })
if not h then
  return err
end
local ok, terr = psi.process_terminate(h)
if not ok then
  return terr
end
local r = psi.process_finish(h)
return tostring(r.status)
