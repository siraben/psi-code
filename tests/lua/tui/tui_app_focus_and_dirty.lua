--[==[psi-test
expect = "true|true|2|true|false|true|false|true"
]==]
local app_mod = require("psi.tui_app")
local component = require("psi.tui_component")

local app = app_mod.new()
local base = { focused = false, render = function() return {} end, invalidate = function() end }
local text = component.text("1", 0, 0)
local overlay = {
  focused = false,
  render = function(_, width)
    return text:render(width)
  end,
  invalidate = function()
    text:invalidate()
  end,
  handle_key = function(_, event)
    text:set_text(event and event.text or "")
    return true
  end,
}

app:set_focus(base)
local handle = app:show_overlay(overlay, { width = 4 })
local focused_after_show = handle.is_focused()
local base_blurred = not base.focused
app:consume_dirty()
local consumed = app:dispatch_key({ key = "x", text = "2" })
local dirty_after_key = app.dirty
local lines = app:render(8, 3)
handle.hide()

return table.concat({
  tostring(focused_after_show),
  tostring(base_blurred),
  lines[2]:match("2") or "",
  tostring(consumed),
  tostring(handle.is_focused()),
  tostring(base.focused),
  tostring(app:has_overlay()),
  tostring(dirty_after_key),
}, "|")
