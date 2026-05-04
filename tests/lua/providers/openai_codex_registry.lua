--[==[psi-test
expect = "openai-codex|openai-codex-responses|gpt-5.5|272000|true"
]==]
local p = require("psi.api_registry")
local desc = p.resolve_descriptor("openai-codex/gpt-5.5")
local model = p.model("openai-codex/gpt-5.5")
return table.concat({desc.provider, desc.api, desc.id,
  tostring(model.context_window), tostring(model.supports_tool_use)}, "|")
