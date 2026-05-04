--[==[psi-test
expect = "true|true|true|true|true"
]==]
-- After a redraw the cursor sits inside the input box, not below the
-- live region. The next redraw must move up by chat_cursor_offset
-- (cursor-row to live-region-top), NOT by chat_live_rows. Otherwise
-- each keystroke shifts the live region up the screen and erases
-- whatever's above it (the user's shell prompt and scrollback).
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "set_input", text = "" },
  { kind = "set_input", text = "a" },
  { kind = "set_input", text = "ab" },
})
local s2, s3 = snapshots[2], snapshots[3]
local up_seq = "\27[" .. tostring(snapshots[1].cursor_offset) .. "F"
return table.concat({
  tostring(s2.cursor_offset == snapshots[1].cursor_offset),
  tostring(s3.cursor_offset == s2.cursor_offset),
  tostring(s2.cursor_offset > 0),
  tostring(s2.cursor_offset < s2.live_rows),
  tostring(s2.output:sub(1, #up_seq) == up_seq),
}, "|")
