--[==[psi-test
expect = "true|true"
]==]
-- Rebuilding the transcript for /resume must retain the previous chat live
-- region's cursor anchor long enough to erase the old input box.
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "user", text = "old session" },
  {
    kind = "rebuild",
    entries = {
      { role = "user", text = "resumed session" },
      { role = "info", text = "resumed /tmp/session.jsonl (1 messages)" },
    },
  },
})
local before, resumed = snapshots[1], snapshots[2]
local up = "\27[" .. tostring(before.cursor_offset) .. "F\27[J"
return table.concat({
  tostring(before.cursor_offset > 0),
  tostring(resumed.output:sub(1, #up) == up),
}, "|")
