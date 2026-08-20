--[==[psi-test
expect = "xold prompt|1|draft|5|draft|2"
]==]
local rt = require("psi.tui_runtime")

local recalled = rt._debug_history_sequence({ "old prompt" }, { "arrow-up", "type" }, "")
local restored = rt._debug_history_sequence({ "old prompt" }, { "arrow-up", "arrow-down" }, "draft")
local restored_middle =
  rt._debug_history_sequence({ "old prompt" }, { "line-up", "line-down" }, "draft", 2)

return table.concat({
  recalled.input,
  tostring(recalled.cursor),
  restored.input,
  tostring(restored.cursor),
  restored_middle.input,
  tostring(restored_middle.cursor),
}, "|")
