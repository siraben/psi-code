--[[psi-test
expect = "1048576|65536|400000|678|openai/gpt-5.1-codex|openrouter"
env = { PSI_OPENROUTER_MODELS_CACHE = "{TMP}/openrouter_models.json" }
[[files]]
path = "openrouter_models.json"
json = { "google/gemini-3-flash-preview" = { context_window = 1048576, max_output_tokens = 65536, reasoning = true, supports_tool_use = true, input = ["text", "image"] }, "openai/gpt-5.1-codex" = { context_window = 400000, max_output_tokens = 128000, reasoning = true, supports_tool_use = true, input = ["text"] }, "fake/provider-model" = { context_window = 12345, max_output_tokens = 678, reasoning = false, supports_tool_use = true, input = ["text"] } }
]]
local providers = require("psi.api_registry")
local full = providers.model("openrouter/google/gemini-3-flash-preview")
local slug = providers.model("google/gemini-3-flash-preview")
local codex = providers.model("openrouter/openai/gpt-5.1-codex")
local fake = providers.model("openrouter/fake/provider-model")
local resolved = providers.resolve_descriptor("openrouter/openai/gpt-5.1-codex")
return table.concat({
  tostring(full.context_window),
  tostring(slug.max_output_tokens),
  tostring(codex.context_window),
  tostring(fake.max_output_tokens),
  tostring(resolved.id),
  tostring(resolved.provider),
}, "|")
