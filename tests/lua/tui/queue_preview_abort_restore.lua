--[==[psi-test
expect = "one queued\n\ndraft|0|true|nil|steer\n\nfollow\n\noriginal draft|0|true|nil|follow only|0|true"
env = { HOME = "{TMP}/keybindings-home" }
files = [
  { path = "keybindings-home/.config/psi/keybindings.json", json = { "app.interrupt" = "ctrl-x", "tui.queue.previous" = "ctrl-p", "tui.queue.next" = "ctrl-n" } },
]
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")

local function text(value)
  return { key = "text", text = value }
end

agent.clear_queues()
psi.abort_reset()
agent.queue_follow_up("one queued")
local one = rt._debug_edit_keys("draft", 5, {
  { key = "ctrl-p" },
  text(" edited preview"),
  { key = "ctrl-x" },
  { key = "ctrl-x" },
}, false, { busy = true })
local one_count = agent.pending_message_count()
local one_aborted = psi.is_aborted()

agent.clear_queues()
psi.abort_reset()
agent.queue_steering("steer")
agent.queue_follow_up("follow")
local multiple = rt._debug_edit_keys("original draft", 8, {
  { key = "ctrl-n" },
  { key = "ctrl-n" },
  text(" changed"),
  { key = "ctrl-x" },
}, false, { busy = true })
local multiple_count = agent.pending_message_count()
local multiple_aborted = psi.is_aborted()

agent.clear_queues()
psi.abort_reset()
agent.queue_follow_up("follow only")
local empty_draft = rt._debug_edit_keys("", 0, {
  { key = "ctrl-p" },
  { key = "ctrl-x" },
}, false, { busy = true })

return table.concat({
  one.input,
  tostring(one_count),
  tostring(one_aborted),
  tostring(one.queue_nav_index),
  multiple.input,
  tostring(multiple_count),
  tostring(multiple_aborted),
  tostring(multiple.queue_nav_index),
  empty_draft.input,
  tostring(agent.pending_message_count()),
  tostring(psi.is_aborted()),
}, "|")
