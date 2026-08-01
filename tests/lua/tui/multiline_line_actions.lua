--[==[psi-test
expect = "3|5|aa\nb|3|aa\nb|4|aabb|2|aabb|2"
]==]
local rt = require("psi.tui_runtime")
local home = rt._debug_edit_keys("aa\nbb", 4, { { key = "home" } }, false)
local finish = rt._debug_edit_keys("aa\nbb", 4, { { key = "end" } }, false)
local kill_start = rt._debug_edit_keys("aa\nbb", 4, { { key = "ctrl-u" } }, false)
local kill_end = rt._debug_edit_keys("aa\nbb", 4, { { key = "ctrl-k" } }, false)
local join_back = rt._debug_edit_keys("aa\nbb", 3, { { key = "ctrl-u" } }, false)
local join_forward = rt._debug_edit_keys("aa\nbb", 2, { { key = "ctrl-k" } }, false)
return table.concat({
  tostring(home.cursor),
  tostring(finish.cursor),
  kill_start.input,
  tostring(kill_start.cursor),
  kill_end.input,
  tostring(kill_end.cursor),
  join_back.input,
  tostring(join_back.cursor),
  join_forward.input,
  tostring(join_forward.cursor),
}, "|")
