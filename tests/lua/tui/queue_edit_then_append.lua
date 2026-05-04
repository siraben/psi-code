--[[psi-test
expect = "first queued|edited queued|third queued|nil"
]]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
agent.queue_follow_up("first queued")
agent.queue_follow_up("second queued")
local function text(s) return {key="text", text=s} end
local state = rt._debug_edit_keys("", 0, {
  {key="ctrl-p"}, {key="ctrl-a"}, {key="ctrl-k"}, text("edited queued"),
  {key="enter"}, text("third queued"), {key="enter"}
}, false, {busy=true})
local pending = agent.pending_messages()
return table.concat({
  pending[1].text,
  pending[2].text,
  pending[3].text,
  tostring(state.queue_nav_index)
}, "|")
