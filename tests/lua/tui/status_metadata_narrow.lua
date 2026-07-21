--[==[psi-test
expect = "32|true|true"
]==]
local tui = require("psi.tui_status")
local text = require("psi.tui_text")
local bar = tui.compose_bar(
  tui.status_bar({
    model = "openai-codex/gpt-5.6-sol",
    thinking_level = "xhigh",
    busy = false,
    scroll = 0,
  }),
  32
)
local plain = text.strip_ansi(bar)
return table.concat({
  tostring(text.visible_width(bar)),
  tostring(plain:find("session", 1, true) ~= nil),
  tostring(plain:find("model", 1, true) ~= nil),
}, "|")
