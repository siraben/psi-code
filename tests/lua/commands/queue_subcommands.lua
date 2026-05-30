--[==[psi-test
expect = "queued steering message|queued follow-up message|steering:first|follow-up:second|set steering queue mode to all|set follow-up queue mode to all|all|all|queue state\n  steeringMode: all\n  followUpMode: all\n  pendingMessageCount: 2|pendingMessageCount: 2|cleared 1 steering queued message(s)|1|follow-up|cleared 1 follow-up queued message(s)|0"
]==]
local agent = require("psi.agent_session")
local c = require("psi.slash_commands")
agent.clear_queues()
local steer = c.handle("/queue steer first").payload
local follow = c.handle("/queue follow-up second").payload
local pending = agent.pending_messages()
local mode_steer = c.handle("/queue set_steering_mode all").payload
local mode_follow = c.handle("/queue set_follow_up_mode all").payload
local modes = agent.queue_modes()
local state = c.handle("/queue state").payload
local count = c.handle("/queue count").payload
local cleared = c.handle("/queue clear steering").payload
local left = agent.pending_message(1)
local left_count = agent.pending_message_count()
local cleared_follow = c.handle("/queue clear-follow-up").payload
return table.concat({
  steer,
  follow,
  pending[1].kind .. ":" .. pending[1].text,
  pending[2].kind .. ":" .. pending[2].text,
  mode_steer,
  mode_follow,
  modes.steering,
  modes["follow-up"],
  state,
  count,
  cleared,
  tostring(left_count),
  left.kind,
  cleared_follow,
  tostring(agent.pending_message_count()),
}, "|")
