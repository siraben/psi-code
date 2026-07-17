--[==[psi-test
expect = "true|5|old2|foo|true"
]==]
local rt = require("psi.tui_runtime")

local a = rt._debug_history_sequence({}, { "arrow-up" }, "aa\nbb\ncc")
local b = rt._debug_history_sequence({ "old1", "old2" }, { "arrow-up", "arrow-up" }, "foo")
local c = rt._debug_history_sequence(
  { "old1", "old2" },
  { "arrow-up", "arrow-up", "arrow-down" },
  "foo"
)

return tostring(a.input == "aa\nbb\ncc")
  .. "|"
  .. tostring(a.cursor)
  .. "|"
  .. b.input
  .. "|"
  .. c.input
  .. "|"
  .. tostring(c.history_index == nil)
