--[==[psi-test
expect = "function_call_output|table|input_text|input_image|data:image/png;base64,abc|string|Read image file [image/png]\n(tool image omitted: model does not support images)"
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
local wire = d.response_input_from_session(s.messages(), "", nil, "gpt-5.5")
local text_only = d.response_input_from_session(s.messages(), "", nil, "gpt-5.3-codex-spark")
return table.concat({
  wire[2].type,
  type(wire[2].output),
  wire[2].output[1].type,
  wire[2].output[2].type,
  wire[2].output[2].image_url,
  type(text_only[2].output),
  text_only[2].output,
}, "|")
