--[[psi-test
contains = ["ext:normal", "ext:visual"]
]]
local tui = require("psi.tui_status")
tui.register_status_hook(function(arg) return "ext:" .. tostring(arg.editor_mode) end)
local line = tui.status_line(
  psi.json_encode({model="m", busy=false, scroll=0, editor_mode="normal"}))
local bar = tui.status_bar(
  psi.json_encode({model="m", busy=false, scroll=0, editor_mode="visual"}))
tui.clear_status_hooks()
return line .. "|" .. bar
