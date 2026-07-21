--[==[psi-test
expect = "true|true|true"
]==]
local commands = require("psi.slash_commands")
local anthropic = commands.handle("/describe provider:anthropic").payload
local codex = commands.handle("/describe provider:openai-codex").payload
return table.concat({
  tostring(anthropic:find("API key via /login anthropic", 1, true) ~= nil),
  tostring(anthropic:find("ANTHROPIC_API_KEY", 1, true) ~= nil),
  tostring(codex:find("OAuth via /login openai-codex", 1, true) ~= nil),
}, "|")
