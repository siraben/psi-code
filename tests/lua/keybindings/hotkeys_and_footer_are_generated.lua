--[[psi-test
contains = ["Ctrl-Z|Alt-D|true|Enter queue", "Ctrl-Z abort", "1|ctrl-z"]
env = { HOME = "{TMP}/keybindings-home" }
files = [
  { path = "keybindings-home/.config/psi/keybindings.json", json = { "app.interrupt" = "ctrl-z", "tui.input.newLine" = "alt-d", "app.redraw" = "ctrl-z" } },
]
]]
local kb = require("psi.keybindings")
local hotkeys = kb.hotkeys_text()
local footer = kb.footer_hint(psi.json_encode({ busy = true }))
return kb.display("app.interrupt") .. "|"
  .. kb.display("tui.input.newLine") .. "|"
  .. tostring(hotkeys:find("Ctrl%-Z") ~= nil) .. "|"
  .. footer .. "|"
  .. tostring(#kb.conflicts()) .. "|"
  .. tostring(kb.conflicts()[1].key)
