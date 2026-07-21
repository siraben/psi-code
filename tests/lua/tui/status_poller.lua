--[==[psi-test
expect = "50|false|50|true|-1|2"
]==]
local tui = require("psi.tui_status")
local calls = 0
tui.clear_status_pollers()
tui.register_status_poller(function()
  calls = calls + 1
  if calls == 1 then
    return false, true
  end
  return true, false
end)
local a = tui.status_poll_timeout()
local b = tui.poll_status()
local c = tui.status_poll_timeout()
local d = tui.poll_status()
local e = tui.status_poll_timeout()
tui.clear_status_pollers()
return table.concat(
  { tostring(a), tostring(b), tostring(c), tostring(d), tostring(e), tostring(calls) },
  "|"
)
