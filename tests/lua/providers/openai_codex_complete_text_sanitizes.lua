--[==[psi-test
expect = "ab|cd|false|nil"
]==]
local d = require("psi.providers.openai_codex")._debug
local body = d.complete_text_request_body({
  system_prompt = "a\x88b",
  user_text = "c\x88d",
  max_tokens = 123,
}, "gpt-5.5")
return table.concat({
  body.instructions,
  body.input[1].content[1].text,
  tostring(body.stream),
  tostring(body.tools),
}, "|")
