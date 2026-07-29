--[==[psi-test
expect = "assistant|6|true|true|true"
]==]
local prompt = require("psi.prompt")
local session = require("psi.session_manager")

session.append_user("first")
session.append_assistant("", {
  { type = "tool_use", id = "call-1", name = "read", input = { path = "old.txt" } },
}, {})
session.append_tool_result("call-1", "read", "important old output", false)
session.append_user("again")
session.append_assistant("", {
  { type = "tool_use", id = "call-2", name = "bash", input = { command = "pwd" } },
}, {})
session.append_tool_result("call-2", "bash", "important recent output", false)

local plan = session.prepare_compaction({ keep_recent_messages = 1 })
local main_request = prompt.compaction_request(plan)[2]
local prefix_request = prompt.turn_prefix_request(plan)[2]
local accounted = #plan.messages_to_summarize + #plan.turn_prefix + #plan.tail

return table.concat({
  plan.tail[1].role,
  tostring(accounted),
  tostring(main_request:find("read%(path=\"old.txt\"%)") ~= nil),
  tostring(main_request:find("important old output", 1, true) ~= nil),
  tostring(prefix_request:find("[User]: again", 1, true) ~= nil),
}, "|")
