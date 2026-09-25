--[==[psi-test
expect = "true"
]==]
local agent = require("psi.agent_session")
local session = require("psi.session_manager")
for i = 1, 10 do
  session.append_user("message " .. i)
end

local before_count, start_count, end_count = 0, 0, 0
psi.events.on("session_before_compact", function(payload)
  before_count = before_count + 1
  if before_count == 1 then
    payload.cancel = true
  else
    payload.summary = "Summary from extension"
  end
end)
psi.events.on("compaction-start", function() start_count = start_count + 1 end)
psi.events.on("session_compact", function() end_count = end_count + 1 end)

local original = psi.session_message_count()
local cancelled, cancel_reason = agent.run_compact({ keep_recent = 2 })
local unchanged = psi.session_message_count() == original
local compacted, summary = agent.run_compact({ keep_recent = 2 })
local projected = session.messages()

return tostring(
  not cancelled and cancel_reason == "compaction cancelled" and unchanged
  and compacted and summary == "Summary from extension"
  and before_count == 2 and start_count == 1 and end_count == 1
  and projected[1].role == "compaction-summary"
  and projected[1].text == "Summary from extension"
)
