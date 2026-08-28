--[==[psi-test
expect = "6|true|false"
]==]
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "ansi", text = "first\rsecond" },
})
local snapshot = snapshots[1]

return table.concat({
  snapshot.live_rows,
  tostring(
    snapshot.output:find("first", 1, true) ~= nil and snapshot.output:find("second", 1, true) ~= nil
  ),
  tostring(snapshot.output:find("first second", 1, true) ~= nil),
}, "|")
