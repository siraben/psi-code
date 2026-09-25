--[==[psi-test
expect = "true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local context = require("psi.context")
local session = require("psi.session_manager")
local text = require("psi.tui_text")
local tui = require("psi.tui_status")
local old_messages = session.messages
local old_estimate = context.estimate_context_tokens
local old_ansi = ansi.enabled
local old_color = ansi.color_enabled
session.messages = function()
  return {
    {
      role = "assistant",
      data = psi.json_encode({ message = { usage = { input = 1500, output = 250, cacheRead = 500 } } }),
    },
  }
end
context.estimate_context_tokens = function() return { tokens = 75 } end
ansi.enabled = true
ansi.color_enabled = true
local arg = {
  model = "openai-codex/gpt-5.5",
  context_window = 100,
  thinking_level = "high",
}
local bar = tui.compose_bar(tui.status_bar(arg), 100)
local plain = text.strip_ansi(bar)
local warning = bar:find("\27[" .. ansi.resolve("33") .. "m75.0%", 1, true) ~= nil
context.estimate_context_tokens = function() return { tokens = 95 } end
local error_bar = tui.status_bar(arg)
local critical = error_bar:find("\27[" .. ansi.resolve("31") .. "m95.0%", 1, true) ~= nil
ansi.color_enabled = false
local no_color = tui.status_bar(arg)
session.messages = old_messages
context.estimate_context_tokens = old_estimate
ansi.enabled = old_ansi
ansi.color_enabled = old_color
return table.concat({
  tostring(plain:find("↑1.5k ↓250 R500 CH25.0%% 75.0%%/100", 1, false) ~= nil),
  tostring(plain:find("gpt-5.5 • high", 1, true) ~= nil),
  tostring(warning),
  tostring(critical),
  tostring(no_color == text.strip_ansi(no_color)),
}, "|")
