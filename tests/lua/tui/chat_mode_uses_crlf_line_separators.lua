--[==[psi-test
expect = "0|true"
]==]
-- Raw mode disables OPOST, so a bare "\n" is just LF — the cursor moves
-- down but stays at the previous column. Without "\r" before each newline,
-- every committed and live-region line gets emitted starting where the
-- previous line ended, producing a staircase artifact.
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "user", text = "hello" },
  { kind = "assistant", text = "Hello! How can I help you today?" },
})
local s = snapshots[2]
local _, bare_lf = s.output:gsub("[^\r]\n", "")
local _, crlf = s.output:gsub("\r\n", "")
return tostring(bare_lf) .. "|" .. tostring(crlf > 0)
