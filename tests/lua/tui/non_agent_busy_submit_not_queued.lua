--[==[psi-test
expect = "draft|0|busy|1"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
local state = rt._debug_edit_keys("draf", 4, {
  { key = "text", text = "t" },
  { key = "enter" },
}, false, {busy=true, busy_kind="compact"})
return state.input
  .. "|" .. tostring(agent.pending_message_count())
  .. "|" .. tostring(state.status_text)
  .. "|" .. tostring(state.editor_undo_count)
