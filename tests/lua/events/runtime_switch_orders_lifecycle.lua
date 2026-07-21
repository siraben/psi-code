--[==[psi-test
expect = "start:load,shutdown,start:load,shutdown|true|true"
files = [
  { path = "first.jsonl", text = "" },
  { path = "second.jsonl", text = "" },
]
]==]
local seen = {}
psi.events.on("session-start", function(payload)
  seen[#seen + 1] = "start:" .. tostring(payload.source)
end)
psi.events.on("session-shutdown", function()
  seen[#seen + 1] = "shutdown"
end)

local runtime = require("psi.agent_session_runtime").new({
  session_file = TMP .. "/first.jsonl",
})
local started = runtime:bootstrap()
local switched = runtime:switch_session(TMP .. "/second.jsonl")
runtime:shutdown()
runtime:shutdown()

return table.concat(seen, ",") .. "|" .. tostring(started) .. "|" .. tostring(switched)
