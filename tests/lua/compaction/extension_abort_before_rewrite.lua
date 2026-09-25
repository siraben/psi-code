--[==[psi-test
expect = "true"
]==]
local agent = require("psi.agent_session")
local session = require("psi.session_manager")
for i = 1, 10 do
  session.append_user("message " .. i)
end

local aborted = false
local rewrite_started = false
psi.events.on("session_before_compact", function(payload)
  payload.summary = "Ready summary"
  aborted = true
end)
psi.events.on("compaction-start", function()
  rewrite_started = true
end)

local original = psi.session_message_count()
local ok, reason = agent.run_compact({
  keep_recent = 2,
  abort_check = function() return aborted end,
})
return tostring(not ok and reason == "compaction cancelled"
  and not rewrite_started and psi.session_message_count() == original)
