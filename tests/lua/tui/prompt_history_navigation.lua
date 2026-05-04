--[==[psi-test
expect = "true|second|sec|3"
]==]
local rt = require("psi.tui_runtime")
local no_history = rt._debug_history_sequence({}, {"line-up"}, "")
local empty = rt._debug_history_sequence({"first", "second"}, {"line-up"}, "")
local draft = rt._debug_history_sequence({"first", "second"}, {"line-up", "line-down"}, "sec")
return tostring(no_history.scrolled) .. "|" .. empty.input .. "|"
  .. draft.input .. '|' .. tostring(draft.cursor)
