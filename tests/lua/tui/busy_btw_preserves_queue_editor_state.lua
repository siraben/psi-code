--[==[psi-test
expect = "|0|1|queued text|nil|insert|nil|warning|Wait for the current response to finish before asking a side question."
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")

agent.clear_queues()
agent.queue_steering("queued text")

local state = rt._debug_edit_keys("/btw later", 10, { { key = "enter" } }, false, {
  busy = true,
  busy_kind = "agent",
})
local pending = agent.pending_message(1)

return table.concat({
  state.input,
  tostring(state.cursor),
  tostring(agent.pending_message_count()),
  tostring(pending and pending.text),
  tostring(state.queue_nav_index),
  tostring(state.editor_mode),
  tostring(state.status_text),
  tostring(state.last_entry_kind),
  tostring(state.last_entry_text),
}, "|")
