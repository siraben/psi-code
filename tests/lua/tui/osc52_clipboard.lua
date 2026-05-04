--[==[psi-test
expect = "aGVsbG8=|true|true|true|true|false|1"
]==]
local tui = require("psi.tui_status")
local osc52 = require("psi.extensions.osc52_clipboard")
local writes = {}
psi.stdout_write = function(text) writes[#writes + 1] = text end
osc52.disable(psi)
tui.clear_clipboard_writers()
osc52.enable(psi)
local wrote = tui.write_clipboard("hi", {source="test", force=true})
local direct = osc52._debug_osc52_sequence("hi", {TMUX=""})
local tmux = osc52._debug_osc52_sequence("hi", {TMUX="/tmp/tmux"})
local capped = osc52.write_clipboard(string.rep("a", 75001), {source="test"})
return table.concat({
  osc52._debug_base64_encode("hello"),
  tostring(wrote),
  tostring((writes[1] or ""):find("52;", 1, true) ~= nil and (writes[1] or ""):find(";aGk=", 1, true) ~= nil),
  tostring(direct:sub(1, 2) == "\27]"),
  tostring(tmux:sub(1, 7) == "\27Ptmux;"),
  tostring(capped),
  tostring(#writes)
}, "|")
