--[==[psi-test
expect = "draft|0|busy"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
local state = rt._debug_edit_keys("draft", 5, {{key="enter"}}, false, {busy=true, busy_kind="compact"})
return state.input .. "|" .. tostring(agent.pending_message_count()) .. "|" .. tostring(state.status_text)
