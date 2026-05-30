--[==[psi-test
expect = "steer\n\nfollow\n\ndraft|0|nil|true"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
agent.queue_steering("steer")
agent.queue_follow_up("follow")
local state = rt._debug_edit_keys("draft", 5, {{key="escape"}}, false, {busy=true})
return state.input .. "|" .. tostring(agent.pending_message_count()) .. "|"
  .. tostring(state.status_text) .. "|" .. tostring(psi.is_aborted())
