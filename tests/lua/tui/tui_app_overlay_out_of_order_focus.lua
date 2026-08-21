--[==[psi-test
expect = "base-1|base-2|base-3|true|false|false|false"
]==]
local app_mod = require("psi.tui_app")

local function focusable(name, seen)
  return {
    focused = false,
    render = function()
      return { name }
    end,
    handle_key = function(_, event)
      seen[#seen + 1] = name .. "-" .. tostring(event and event.text)
      return true
    end,
  }
end

local seen = {}

-- Removing an overlay below the focused overlay must retarget the focused
-- overlay's eventual restoration away from the removed component.
local app = app_mod.new()
local base = focusable("base", seen)
local overlay_a = focusable("a", seen)
local overlay_b = focusable("b", seen)
app:set_focus(base)
local handle_a = app:show_overlay(overlay_a)
local handle_b = app:show_overlay(overlay_b)
handle_a.hide()
handle_b.hide()
app:dispatch_key({ key = "x", text = "1" })

-- Retargeting must follow a nested restoration chain when intermediate
-- overlays are removed before both their parent and child.
local app_nested = app_mod.new()
local nested_base = focusable("base", seen)
local nested_a = focusable("a", seen)
local nested_b = focusable("b", seen)
local nested_c = focusable("c", seen)
app_nested:set_focus(nested_base)
local nested_handle_a = app_nested:show_overlay(nested_a)
local nested_handle_b = app_nested:show_overlay(nested_b)
local nested_handle_c = app_nested:show_overlay(nested_c)
nested_handle_b.hide()
nested_handle_a.hide()
nested_handle_c.hide()
app_nested:dispatch_key({ key = "x", text = "2" })

-- Removing the oldest ancestor first must preserve the remaining nested
-- overlay focus order before ultimately restoring the base component.
local app_oldest_first = app_mod.new()
local oldest_base = focusable("base", seen)
local oldest_a = focusable("a", seen)
local oldest_b = focusable("b", seen)
local oldest_c = focusable("c", seen)
app_oldest_first:set_focus(oldest_base)
local oldest_handle_a = app_oldest_first:show_overlay(oldest_a)
local oldest_handle_b = app_oldest_first:show_overlay(oldest_b)
local oldest_handle_c = app_oldest_first:show_overlay(oldest_c)
oldest_handle_a.hide()
oldest_handle_c.hide()
local restored_nested_overlay = oldest_handle_b.is_focused()
oldest_handle_b.hide()
app_oldest_first:dispatch_key({ key = "x", text = "3" })

return table.concat({
  seen[1] or "",
  seen[2] or "",
  seen[3] or "",
  tostring(restored_nested_overlay),
  tostring(overlay_a.focused),
  tostring(nested_a.focused),
  tostring(oldest_a.focused),
}, "|")
