--[==[psi-test
expect = "|0|nil|queued text edited|1|draft|draft|nil"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
local same = rt._debug_consume_queued_preview("queued text", "queued text")
local edited = rt._debug_consume_queued_preview("queued text edited", "queued text")

agent.clear_queues()
agent.queue_follow_up("still queued")
local remaining = agent.pending_message(1)
local other_consumed = rt._debug_consume_queued_preview("still queued edited", "consumed first", {
  queue_nav_id = remaining.id,
  queue_nav_draft = "draft",
  queue_nav_draft_cursor = 2,
})
agent.clear_queues()
local current_consumed = rt._debug_consume_queued_preview("consumed edited", "consumed", {
  queue_nav_id = remaining.id,
  queue_nav_draft = "draft",
  queue_nav_draft_cursor = 2,
})
return table.concat({
  same.input,
  tostring(same.cursor),
  tostring(same.queue_nav_index),
  edited.input,
  tostring(other_consumed.queue_nav_index),
  tostring(other_consumed.queue_nav_draft),
  current_consumed.input,
  tostring(current_consumed.queue_nav_index),
}, "|")
