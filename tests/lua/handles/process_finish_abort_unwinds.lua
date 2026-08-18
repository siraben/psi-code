--[==[psi-test
expect = "true|130|true"
]==]
-- Regression: Ctrl-C (abort) must unwind a tool call whose child
-- outlives its output stream. Before the fix, finish() blocked in an
-- abort-blind waitpid and the turn (and psi) wedged until SIGKILL.
local h = assert(psi.process_begin("exec 1>&- 2>&-; sleep 60"))
local done = false
for _ = 1, 40 do
  local _, d = psi.process_poll(h, 25)
  if d then
    done = true
    break
  end
end
psi.abort_trigger()
local t0 = psi.time_ms()
local r = psi.process_finish(h)
local elapsed = psi.time_ms() - t0
psi.abort_reset()
return tostring(done) .. "|" .. tostring(r.status) .. "|" .. tostring(elapsed < 5000)
