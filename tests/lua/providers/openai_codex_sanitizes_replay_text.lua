--[==[psi-test
expect = "ab|cd|ef|gh"
]==]
local s = require("psi.session_manager")
local d = require("psi.providers.openai_codex")._debug

s.append_user("a\x88b")
s.append_assistant("c\x88d", {
  { type = "text", text = "c\x88d" },
  { type = "tool_use", id = "call_1|item_1", name = "bash", input = { command = "pwd" } },
}, {})
s.append_tool_result("call_1|item_1", "bash", "e\x88f", false)
s.append_custom_message("g\x88h", { role = "assistant" })

local wire = d.response_input_from_session(s.messages(), "")
return table.concat({
  wire[1].content[1].text,
  wire[2].content[1].text,
  wire[4].output,
  wire[5].content[1].text,
}, "|")
