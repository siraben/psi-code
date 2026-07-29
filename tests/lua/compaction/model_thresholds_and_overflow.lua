--[==[psi-test
expect = "272000|1048576|1000000|true|false|true"
]==]
local context = require("psi.context")

return table.concat({
  tostring(context.context_window("gpt-5.6-terra", "openai-codex")),
  tostring(context.context_window("k3", "moonshot")),
  tostring(context.context_window("claude-opus-4-8", "anthropic")),
  tostring(context.is_overflow_error("Your request exceeded model token limit: 100 (requested: 101)")),
  tostring(context.is_overflow_error("rate limit: too many tokens, retry later")),
  tostring(context.is_overflow_error("413 status code (no body)")),
}, "|")
