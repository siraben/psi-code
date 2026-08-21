--[==[psi-test
expect = "queued\n\ndraft|0|nil|true"
env = { HOME = "{TMP}/keybindings-home" }
files = [
  { path = "keybindings-home/.config/psi/keybindings.json", json = { "tui.queue.previous" = "ctrl-p" } },
]
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")

agent.clear_queues()
psi.abort_reset()
agent.queue_follow_up("queued")
local state = rt._debug_edit_keys("draft", 5, {
  { key = "ctrl-p" },
  { key = "text", text = " edited preview" },
  { key = "escape" },
}, false, { busy = true })

return table.concat({
  state.input,
  tostring(agent.pending_message_count()),
  tostring(state.queue_nav_index),
  tostring(psi.is_aborted()),
}, "|")
