--[[psi-test
expect = "|0|nil|queued text edited"
]]
local rt = require("psi.tui_runtime")
local same = rt._debug_consume_queued_preview("queued text", "queued text")
local edited = rt._debug_consume_queued_preview("queued text edited", "queued text")
return table.concat({
  same.input,
  tostring(same.cursor),
  tostring(same.queue_nav_index),
  edited.input
}, "|")
