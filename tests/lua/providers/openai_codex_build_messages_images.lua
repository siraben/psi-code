--[==[psi-test
expect = "table|input_image"
]==]
local s = require("psi.session_manager")
local d = require("psi.providers.openai_codex")._debug
s.append_assistant("", {
  { type = "tool_use", id = "call_1|item_1", name = "read", input = { path = "tiny.png" } },
}, {})
s.append_tool_result("call_1|item_1", "read", "{}", false, {
  { type = "text", text = "Read image file [image/png]" },
  { type = "image", mimeType = "image/png", data = "abc" },
})
local wire = d.build_messages(s.messages(), "", nil, "gpt-5.5")
return type(wire[2].output) .. "|" .. wire[2].output[2].type
