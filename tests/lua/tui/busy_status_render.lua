--[[psi-test
# Original: stripped equals plain string AND raw output contains "\x1b[96m". Folded.
expect = "working (0:04  • Ctrl-G to interrupt) ...|true"
]]
local ansi = require("psi.ansi")
ansi.color_enabled = true
local rendered = require("psi.tui_status").render_busy_status("working", 2, 4)
local plain = (rendered:gsub("\27%[[%d;]*m", ""))
return plain .. "|" .. tostring(rendered:find("\27[96m", 1, true) ~= nil)
