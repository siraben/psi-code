--[==[psi-test
expect = "true|true|true|true"
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
local repl = "\239\191\189"
return table.concat({
  tostring(wire[1].content[1].text == ("a" .. repl .. "b")),
  tostring(wire[2].content[1].text == ("c" .. repl .. "d")),
  tostring(wire[4].output == ("e" .. repl .. "f")),
  tostring(wire[5].content[1].text == ("g" .. repl .. "h")),
}, "|")
