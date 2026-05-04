--[==[psi-test
name = "events/tui_bootstrap_load_fires_single_session_start"
expect = "true|nil|1"
files = [
  { path = "empty-session.jsonl", text = "" },
]
]==]
local count = 0
psi.events.on("session-start", function()
  count = count + 1
end)
local ok, err = require("psi.tui_runtime")._debug_bootstrap_session({
  session_file = TMP .. "/empty-session.jsonl",
})
return tostring(ok) .. "|" .. tostring(err) .. "|" .. tostring(count)
