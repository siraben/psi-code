--[==[psi-test
expect = "true|k|nil|true|false|false"
]==]
local app_mod = require("psi.tui_app")

local app = app_mod.new()
local visible = true
local base_seen
local overlay_seen
local base = {
  focused = false,
  render = function()
    return { "base" }
  end,
  handle_key = function(_, event)
    base_seen = event and event.text
    return true
  end,
}
local overlay = {
  focused = false,
  render = function()
    return { "over" }
  end,
  handle_key = function(_, event)
    overlay_seen = event and event.text
    return true
  end,
}

app:set_focus(base)
app:render(80, 24)
app:show_overlay(overlay, {
  width = 4,
  visible = function()
    return visible
  end,
})
visible = false
app:render(80, 24)
local consumed = app:dispatch_key({ key = "x", text = "k" })

return table.concat({
  tostring(consumed),
  tostring(base_seen),
  tostring(overlay_seen),
  tostring(base.focused),
  tostring(overlay.focused),
  tostring(app:has_overlay()),
}, "|")
