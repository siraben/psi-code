--[==[psi-test
expect = "1|first|1|1|second|0"
]==]
local agent = require("psi.agent_session")
agent.clear_queues()
agent.queue_steering("first")
agent.queue_steering("second")
local first = agent.drain_steering()
local after_first = agent.pending_message_count()
local second = agent.drain_steering()
return tostring(#first) .. "|" .. tostring(first[1]) .. "|" .. tostring(after_first)
  .. "|" .. tostring(#second) .. "|" .. tostring(second[1]) .. "|"
  .. tostring(agent.pending_message_count())
