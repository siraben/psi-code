--[==[psi-test
expect = "ab|cd"
]==]
local d = require("psi.providers.openai_compat")._debug
local messages = d.complete_text_messages({
  system_prompt = "a\x88b",
  user_text = "c\x88d",
})
return messages[1].content .. "|" .. messages[2].content
