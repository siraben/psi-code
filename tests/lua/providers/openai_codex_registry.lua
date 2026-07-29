--[==[psi-test
expect = "openai-codex|openai-codex-responses|gpt-5.6-terra|272000|true|image|text"
]==]
local p = require("psi.api_registry")
local desc = p.resolve_descriptor("openai-codex/gpt-5.6-terra")
local model = p.model("openai-codex/gpt-5.6-terra")
return table.concat(
  {
    desc.provider,
    desc.api,
    desc.id,
    tostring(model.context_window),
    tostring(model.supports_tool_use),
    model.input[2],
    p.model("openai-codex/gpt-5.3-codex-spark").input[1],
  },
  "|"
)
