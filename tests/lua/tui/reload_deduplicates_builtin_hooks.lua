--[==[psi-test
expect = "1|vim-mode|true|1"
cwd = "reload-vim-config"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/settings.json", json = { extensions = { vim_keybindings = { enabled = true } } } },
]
]==]
local commands = require("psi.slash_commands")
local tui = require("psi.tui_status")
commands.handle("/reload")
commands.handle("/reload")
local writes = 0
psi.stdout_write = function() writes = writes + 1 end
local copied = tostring(tui.write_clipboard("hi", {force=true}))
local bar = tui.status_bar({model="m", busy=false, scroll=0, editor_mode="normal"})
local _, count = bar:gsub("mode:NORMAL", "")
local action = tui.handle_key({key="escape", busy=false, input_length=1, editor_mode="insert"})
return tostring(count) .. "|" .. tostring(action and action.action or "nil") .. "|" .. copied .. "|" .. tostring(writes)
