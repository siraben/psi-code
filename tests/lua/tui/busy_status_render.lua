--[==[psi-test
# Original: stripped equals Pi's stable label and braille frame; raw spinner is accented. Folded.
expect = "⠴ working...|true"
]==]
local ansi = require("psi.ansi")
ansi.color_enabled = true
local rendered = require("psi.tui_status").render_busy_status("working", 2, 4, 5)
local plain = (rendered:gsub("\27%[[%d;]*m", ""))
return plain .. "|" .. tostring(rendered:find("\27[38;2;138;190;183m", 1, true) ~= nil)
