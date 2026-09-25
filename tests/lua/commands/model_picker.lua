--[==[psi-test
expect = "model-picker|set-model|openai-codex/gpt-5.5|model-picker"
]==]
local commands = require("psi.slash_commands")
local tui = require("psi.tui_status")
local pick = commands.handle("/model")
local direct = commands.handle("/model openai-codex/gpt-5.5")
local key = tui.handle_key({ key = "ctrl-l", busy = false, input_length = 0 })
return table.concat({ pick.kind, direct.kind, direct.payload, key.action }, "|")
