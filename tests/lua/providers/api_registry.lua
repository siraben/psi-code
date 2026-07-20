--[==[psi-test
expect = "psi.providers.anthropic|anthropic-messages|true|function|5"
]==]
local p = require("psi.api_registry")
local api = p.api("anthropic-messages")
local desc = p.resolve_descriptor("anthropic/claude-opus-4-8")
local mod = p.load_api("anthropic-messages")
return table.concat({
  tostring(api.module),
  tostring(desc.api),
  tostring(desc.compat.supports_tool_use),
  tostring(type(mod.run_turn)),
  tostring(#p.all_apis()),
}, "|")
