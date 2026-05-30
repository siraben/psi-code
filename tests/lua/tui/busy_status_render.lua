--[==[psi-test
# Original: stripped equals plain string AND raw output contains the pi cyan shimmer. Folded.
expect = "working (0:04  • Esc to interrupt) ...|true"
]==]
local ansi = require("psi.ansi")
ansi.color_enabled = true
local rendered = require("psi.tui_status").render_busy_status("working", 2, 4)
local plain = (rendered:gsub("\27%[[%d;]*m", ""))
return plain .. "|" .. tostring(rendered:find("\27[38;2;0;215;255m", 1, true) ~= nil)
