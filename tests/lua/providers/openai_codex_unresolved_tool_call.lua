--[==[psi-test
expect = "function_call|call_1|function_call_output|call_1|No result provided|continue"
]==]
local s = require("psi.session_manager")
local d = require("psi.providers.openai_codex")._debug
s.append_user("hi")
s.append_assistant("", {
  { type = "tool_use", id = "call_1|item_1", name = "bash",
    input = { command = "pwd" } }
}, {})
s.append_user("continue")
local wire = d.response_input_from_session(s.messages(), "")
return table.concat({
  wire[2].type,
  wire[2].call_id,
  wire[3].type,
  wire[3].call_id,
  wire[3].output,
  wire[4].content[1].text,
}, "|")
