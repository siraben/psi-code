--[[psi-test
expect = "true|true|2|follow-up|true|steer|nil|follow edited|0"
]]
local agent = require("psi.agent_session")
agent.clear_queues()
local ok1 = agent.queue_steering("steer")
local ok2 = agent.queue_follow_up({text = "follow"})
local pending = agent.pending_message_count()
local item = agent.pending_message(2)
local edited = agent.replace_pending(2, "follow edited")
local removed = agent.remove_pending(1)
local steering = agent.drain_steering()
local follow = agent.drain_follow_ups()
return tostring(ok1) .. "|" .. tostring(ok2) .. "|"
  .. pending .. "|" .. item.kind .. "|" .. tostring(edited) .. "|"
  .. removed .. "|" .. tostring(steering[1]) .. "|" .. follow[1] .. "|"
  .. agent.pending_message_count()
