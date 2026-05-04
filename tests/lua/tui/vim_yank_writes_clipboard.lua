--[==[psi-test
expect = "abc"
]==]
local tui = require("psi.tui_status")
local rt = require("psi.tui_runtime")
require("psi.extensions.vim_keybindings").enable(psi)
local copied = "-"
tui.clear_clipboard_writers()
tui.register_clipboard_writer(function(text) copied = text return true end)
rt._debug_edit_keys("abc", 0, {{key="escape"}, {key="text", text="y"}}, false, {clipboard_writers=true})
return copied
