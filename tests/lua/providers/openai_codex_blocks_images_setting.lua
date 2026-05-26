--[==[psi-test
expect = "string|Read image file [image/png]\nImage reading is disabled."
cwd = "openai-codex-blocks-images"
files = [
  { path = ".psi/settings.json", json = { images = { block_images = true } } },
]
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
return type(wire[2].output) .. "|" .. wire[2].output
