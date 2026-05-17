--[==[psi-test
expect = "false|false|true|false|false"
]==]
local app_mod = require("psi.tui_app")

local app = app_mod.new()
local base = {
  focused = false,
  render = function()
    return { "base" }
  end,
}
local overlay = {
  focused = false,
  render = function()
    return { "over" }
  end,
  handle_key = function()
    return true
  end,
}

app:set_focus(base)
local handle = app:show_overlay(overlay, { width = 4 })
handle.hide()
handle.focus()
local consumed = app:dispatch_key({ key = "x", text = "x" })

return table.concat({
  tostring(handle.is_focused()),
  tostring(app:has_overlay()),
  tostring(base.focused),
  tostring(overlay.focused),
  tostring(consumed),
}, "|")
