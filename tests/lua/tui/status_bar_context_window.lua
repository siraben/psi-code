--[==[psi-test
contains = "0.3%/1.0M (auto)"
env = { PSI_OPENROUTER_MODELS_CACHE = "{TMP}/openrouter_models_status_bar.json" }
[[files]]
path = "openrouter_models_status_bar.json"
json = { "google/gemini-3-flash-preview" = { context_window = 1048576, max_output_tokens = 65536, reasoning = true, supports_tool_use = true, input = ["text", "image"] } }
]==]
local context = require("psi.context")
local tui = require("psi.tui_status")
local text = require("psi.tui_text")
context.record_usage(0, { input_tokens = 3000, output_tokens = 566 }, "google/gemini-3-flash-preview")
return text.strip_ansi(tui.status_bar({
  model = "openrouter/google/gemini-3-flash-preview",
  busy = false,
  scroll = 0,
}))
