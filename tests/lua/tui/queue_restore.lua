--[==[psi-test
expect = "first queued\n\nsecond queued\n\ndraft|0|Restored 2 queued messages to editor"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
agent.queue_follow_up("first queued")
agent.queue_follow_up("second queued")
local state = rt._debug_edit_keys("draft", 5, {{key="alt-up"}}, false, {busy=true})
return state.input .. "|" .. tostring(agent.pending_message_count()) .. "|"
  .. tostring(state.status_text)
