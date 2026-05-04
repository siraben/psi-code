--[==[psi-test
expect = "true|updated queued message 2|removed queued message 1|changed"
]==]
local agent = require("psi.agent_session")
local c = require("psi.slash_commands")
agent.clear_queues()
agent.queue_follow_up("first queued")
agent.queue_follow_up("second queued")
local list = c.handle("/queue").payload
local edit = c.handle("/queue edit 2 changed").payload
local drop = c.handle("/queue drop 1").payload
local item = agent.pending_message(1)
return tostring(list:find("first queued") ~= nil) .. "|"
  .. edit .. "|" .. drop .. "|" .. item.text
