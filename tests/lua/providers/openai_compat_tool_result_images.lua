--[==[psi-test
expect = "tool|Read image file [image/png]|user|text|image_url|data:image/png;base64,abc|tool|Read image file [image/png]\n(tool image omitted: model does not support images)"
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
cfg.supports_images = false
local text_only = compat.build_api_messages(s.messages(), "", cfg)
return table.concat({
  wire[2].role,
  wire[2].content,
  wire[3].role,
  wire[3].content[1].type,
  wire[3].content[2].type,
  wire[3].content[2].image_url.url,
  text_only[2].role,
  text_only[2].content,
}, "|")
