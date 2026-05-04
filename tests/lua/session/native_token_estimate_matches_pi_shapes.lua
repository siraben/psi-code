--[==[psi-test
expect = "1337|1328"
]==]
local s = require("psi.session_manager")
s.append_assistant("", {
  { type = "text", text = "abcd" },
  { type = "thinking", thinking = "12345678" },
  { type = "tool_use", id = "call-1", name = "bash",
    input = { command = "ls" } },
}, {})
local tool_body = { message = { role = "toolResult", content = {
  { type = "text", text = "abcd" }, { type = "image" },
} } }
s.append_message({ role = "tool-result", text = "abcd", data = psi.json_encode(tool_body) })
return tostring(psi.session_token_estimate_from(1)) .. "|"
  .. tostring(psi.session_token_estimate_from(2))
