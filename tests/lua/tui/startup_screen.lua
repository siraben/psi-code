--[==[psi-test
expect = "true|true|true|true|true|true|true|true"
]==]
local startup = require("psi.tui_startup")
local text = require("psi.tui_text")
local compact = text.strip_ansi(startup.render({ expanded = false }))
local expanded = text.strip_ansi(startup.render({ expanded = true }))
return table.concat({
  tostring(compact:find("▀▀█ █▀▀ ▀ v", 1, true) == 1),
  tostring(expanded:find("█▀  ▄▄█ █", 1, true) ~= nil),
  tostring(compact:find("v" .. psi.version(), 1, true) ~= nil),
  tostring(compact:find("Esc interrupt", 1, true) ~= nil),
  tostring(compact:find("Ctrl-C/Ctrl-D clear/exit", 1, true) ~= nil),
  tostring(compact:find("Ctrl-O more", 1, true) ~= nil),
  tostring(expanded:find("Shift-Tab to cycle thinking level", 1, true) ~= nil),
  tostring(expanded:find("Ctrl-T to expand thinking", 1, true) ~= nil),
}, "|")
