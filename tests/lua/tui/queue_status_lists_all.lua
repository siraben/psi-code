--[==[psi-test
contains = "queue:Follow-up: first queued | Follow-up: second queued"
]==]
local agent = require("psi.agent_session")
local tui = require("psi.tui_status")
agent.clear_queues()
agent.queue_follow_up("first queued")
agent.queue_follow_up("second queued")
return tui.status_line({busy=true, scroll=0})
