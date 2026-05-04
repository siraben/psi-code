--[==[psi-test
expect = "true|true|true"
]==]
-- Chat mode bypasses psi.tui_render_frame entirely so the output flows
-- into the terminal's primary screen scrollback. Every redraw is wrapped
-- in DEC synchronized output so partial frames never tear.
local rt = require("psi.tui_runtime")
local snapshots = rt._debug_chat_redraw_sequence({
  { kind = "user", text = "ping" },
})
local s = snapshots[1]
return table.concat({
  tostring(s.write_count >= 1),
  tostring(s.output:find("\27[?2026h", 1, true) ~= nil),
  tostring(s.output:find("\27[?25h", 1, true) ~= nil),
}, "|")
