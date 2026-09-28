--[==[psi-test
expect = "editor-up|editor-down|scroll:page-up|scroll:top|editor-page:up|cycle-thinking|model-cycle:forward|model-cycle:backward|copy-response|scroll:wheel-up|scroll:wheel-page-up"
]==]
local tui = require("psi.tui_status")
local function action(key, viewport)
  local result = tui.handle_key({ key = key, input_length = 0, viewport = viewport })
  return result.action .. (result.arg and (":" .. result.arg) or "")
end
return table.concat({
  action("up", true),
  action("down", true),
  action("page-up", true),
  action("home", true),
  action("page-up", false),
  action("shift-tab", false),
  action("ctrl-p", false),
  action("shift-ctrl-p", false),
  action("ctrl-x", false),
  action("wheel-up", true),
  action("alt-wheel-up", true),
}, "|")
