--[==[psi-test
expect = "tool|Read image file [image/png]\nImage reading is disabled.|nil"
cwd = "openai-compat-blocks-images"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { images = { block_images = true } } },
]
]==]
local compat = require("psi.providers.openai_compat")
local s = require("psi.session_manager")
s.append_assistant("", {
  { type = "tool_use", id = "call_1", name = "read", input = { path = "tiny.png" } },
}, {})
s.append_tool_result("call_1", "read", "{}", false, {
  { type = "text", text = "Read image file [image/png]" },
  { type = "image", mimeType = "image/png", data = "abc" },
})
local cfg = {
  supports_images = true,
  assistant_tool_call = function(b)
    return { id = b.id, type = "function", ["function"] = { name = b.name, arguments = "{}" } }
  end,
  tool_result_message = function(id, _name, text)
    return { role = "tool", tool_call_id = id, content = text }
  end,
}
local wire = compat.build_api_messages(s.messages(), "", cfg)
return table.concat({
  wire[2].role,
  wire[2].content,
  tostring(wire[3]),
}, "|")
