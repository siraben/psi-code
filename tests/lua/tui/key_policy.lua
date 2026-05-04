--[[psi-test
expect = "submit:-|submit:-|insert:\\n|scroll:page-up|quit:-|nil|queue-restore:-|scroll:line-up|scroll:line-up|scroll:line-down|nil|abort:-|insert:x"
]]
local tui = require("psi.tui_status")
local function fmt(res)
  if not res then return "nil" end
  local arg = res.arg
  if type(arg) == "table" then arg = arg.mode end
  if arg == "\n" then arg = "\\n" end
  return (res.action or "?") .. ":" .. (arg or "-")
end
return table.concat({
  fmt(tui.handle_key({key="enter", busy=false, input_length=1})),
  fmt(tui.handle_key({key="enter", busy=true, input_length=1})),
  fmt(tui.handle_key({key="shift-enter", busy=false, input_length=0})),
  fmt(tui.handle_key({key="ctrl-u", busy=false, input_length=0})),
  fmt(tui.handle_key({key="ctrl-d", busy=false, input_length=0})),
  fmt(tui.handle_key({key="ctrl-d", busy=true, input_length=0})),
  fmt(tui.handle_key({key="up", busy=true, input_length=0, queue_count=2})),
  fmt(tui.handle_key({key="up", busy=true, input_length=0, queue_count=0})),
  fmt(tui.handle_key({key="wheel-up", busy=false, input_length=0})),
  fmt(tui.handle_key({key="wheel-down", busy=false, input_length=0})),
  fmt(tui.handle_key({key="escape", busy=true, input_length=0})),
  fmt(tui.handle_key({key="ctrl-g", busy=true, input_length=0})),
  fmt(tui.handle_key({key="text", text="x"}))
}, "|")
