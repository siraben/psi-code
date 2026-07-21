--[==[psi-test
contains = ["thinking:high", "usage:↑1.5k ↓340 R1.0k W50 CH36.4% $0.015", "gpt-5.6-sol (high)", "usage ↑1.5k ↓340 R1.0k W50 CH36.4% $0.015"]
]==]
psi.session_clear()
psi.session.reset_entry_chain()
psi.session.append_assistant("one", { { type = "text", text = "one" } }, {
  model = "gpt-5.6-sol",
  provider = "openai-codex",
  usage = {
    input_tokens = 1200,
    output_tokens = 300,
    cache_read_input_tokens = 800,
    cost = 0.012,
  },
})
psi.session.append_assistant("two", { { type = "text", text = "two" } }, {
  model = "gpt-5.6-sol",
  provider = "openai-codex",
  usage = {
    input_tokens = 300,
    output_tokens = 40,
    cache_read_input_tokens = 200,
    cache_creation_input_tokens = 50,
    cost = { total = 0.003 },
  },
})
local tui = require("psi.tui_status")
local arg = {
  model = "openai-codex/gpt-5.6-sol",
  thinking_level = "high",
  busy = false,
  scroll = 0,
}
return tui.status_line(arg) .. "|" .. require("psi.tui_text").strip_ansi(tui.status_bar(arg))
