--[[psi-test
# Regression for orphan tool-result after compaction. Pass iff first kept
# role is NOT 'tool-result'. Folded into a boolean return.
expect = "true"
]]
local s = require("psi.session_manager")
local records = require("psi.records")
s.append_user("hi")
s.append_assistant("", {
  { type = "tool_use", id = "call-1", name = "bash",
    input = { command = "ls" } }
}, {})
s.append_tool_result("call-1", "bash", "output1", false)
s.append_user("again")
s.append_assistant("", {
  { type = "tool_use", id = "call-2", name = "bash",
    input = { command = "pwd" } }
}, {})
s.append_tool_result("call-2", "bash", "output2", false)
s.do_compact(1, "summary text here")
local msgs = s.messages()
local first_kept_role = nil
for _, m in ipairs(msgs) do
  if m.role ~= "compaction-summary" then
    first_kept_role = m.role
    break
  end
end
return tostring(first_kept_role ~= "tool-result")
