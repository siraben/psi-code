--[==[psi-test
expect = "true||7|true"
]==]
-- Regression: a child that closes its stdout/stderr and keeps running
-- (daemon-style, or a grandchild blocked on /dev/tty) produces pipe EOF
-- while still alive. finish() must not wedge in an uninterruptible
-- waitpid; it waits for the real exit status and returns.
local h = assert(psi.process_begin("exec 1>&- 2>&-; sleep 0.3; exit 7"))
local done = false
for _ = 1, 40 do
  local _, d = psi.process_poll(h, 25)
  if d then
    done = true
    break
  end
end
local t0 = psi.time_ms()
local r = psi.process_finish(h)
local elapsed = psi.time_ms() - t0
return tostring(done)
  .. "|"
  .. (r.output or "")
  .. "|"
  .. tostring(r.status)
  .. "|"
  .. tostring(elapsed < 5000)
