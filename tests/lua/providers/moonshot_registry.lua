--[==[psi-test
expect = "moonshot|moonshot-messages|psi.providers.moonshot|function|function|kimi-for-coding|anthropic"
]==]
-- Moonshot / Kimi For Coding routes to its own api + module, and its wire
-- format is Anthropic Messages (thinking_format anthropic).
local reg = require("psi.api_registry")

local api = reg.api("moonshot-messages")
local route = reg.resolve_route("moonshot/kimi-for-coding")
local desc = reg.resolve_descriptor("moonshot/kimi-for-coding")
local mod = reg.load_api("moonshot-messages")

return table.concat({
  route.name,
  desc.api,
  api.module,
  tostring(type(mod.run_turn)),
  tostring(type(mod.has_auth)),
  desc.model,
  desc.compat.thinking_format,
}, "|")
