--[==[psi-test
expect = "|1|follow-up|later|nil"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
local state = rt._debug_edit_keys("/queue follow-up later", 22, {{key="enter"}}, false, {busy=true})
local item = agent.pending_message(1)
return table.concat({
  state.input,
  tostring(agent.pending_message_count()),
  item.kind,
  item.text,
  tostring(state.status_text),
}, "|")
