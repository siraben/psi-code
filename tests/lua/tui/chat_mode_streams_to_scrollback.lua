--[==[psi-test
expect = "0|1|1|true|true|true|true"
]==]
-- Drive a chat-mode session through three steps:
--   1. user message added (live region only)
--   2. assistant message added (user becomes committed scrollback)
--   3. input edit (no entry change; just live region repaint)
-- Verify entries get committed exactly once and that input edits don't
-- re-emit committed lines.
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "user", text = "hello" },
  { kind = "assistant", text = "hi there" },
  { kind = "set_input", text = "next message" },
})
local s1, s2, s3 = snapshots[1], snapshots[2], snapshots[3]
return table.concat({
  tostring(s1.committed_entries),
  tostring(s2.committed_entries),
  tostring(s3.committed_entries),
  tostring(s2.output:find("hello", 1, true) ~= nil),
  tostring(s3.output:find("hello", 1, true) == nil),
  tostring(s3.output:find("next message", 1, true) ~= nil),
  tostring(s2.live_rows >= 3),
}, "|")
