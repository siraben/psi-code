--[==[psi-test
expect = "steering:third queued|follow-up:first queued|follow-up:second queued|follow-up:fourth queued"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
agent.clear_queues()
agent.queue_follow_up("first queued")
agent.queue_follow_up("second queued")
local function text(s) return {key="text", text=s} end
local state = rt._debug_edit_keys("", 0, {
  text("third queued"), {key="enter"},
  text("fourth queued"), {key="alt-enter"}
}, false, {busy=true})
local pending = agent.pending_messages()
local out = {}
for i, item in ipairs(pending) do
  out[i] = item.kind .. ":" .. item.text
end
return table.concat(out, "|")
