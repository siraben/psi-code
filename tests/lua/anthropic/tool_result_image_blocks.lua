--[==[psi-test
expect = "tool_result|table|text|image|image/png|abc"
]==]
local a = require("psi.providers.anthropic")
local function msg(role, body)
  return { role = role, text = "", data = psi.json_encode(body) }
end
local session = {
  msg(
    "assistant",
    {
      message = {
        role = "assistant",
        content = {
          { type = "toolCall", id = "toolu_1", name = "read", arguments = { path = "tiny.png" } },
        },
      },
    }
  ),
  msg(
    "tool-result",
    {
      message = {
        role = "toolResult",
        toolCallId = "toolu_1",
        toolName = "read",
        content = {
          { type = "text", text = "Read image file [image/png]" },
          { type = "image", mimeType = "image/png", data = "abc" },
        },
      },
    }
  ),
}
local wire = a._test.build_api_messages(session)
local block = wire[2].content[1]
return table.concat({
  block.type,
  type(block.content),
  block.content[1].type,
  block.content[2].type,
  block.content[2].source.media_type,
  block.content[2].source.data,
}, "|")
