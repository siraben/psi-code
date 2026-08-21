--[==[psi-test
expect = "5|8|5|true|true|true"
]==]
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "set_input", text = "one\ntwo\nthree\nfour\nfive\nsix" },
}, { width = 20, height = 4 })
local snapshot = snapshots[1]

return table.concat({
  snapshot.input_max_rows,
  snapshot.live_rows,
  snapshot.cursor_offset,
  tostring(snapshot.output:find("six", 1, true) ~= nil),
  tostring(snapshot.output:find("one", 1, true) == nil),
  tostring(snapshot.output:find("\27[?25h", 1, true) ~= nil),
}, "|")
