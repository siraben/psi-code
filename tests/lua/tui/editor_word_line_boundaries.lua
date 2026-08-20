--[==[psi-test
expect = "foobar|3|foobar|3|3|4|foo |5|6|12|foo　|6|3|foo👍"
]==]
local rt = require("psi.tui_runtime")

local backward = rt._debug_edit_keys("foo\nbar", 4, { { key = "ctrl-w" } }, false)
local forward = rt._debug_edit_keys("foo\nbar", 3, { { key = "alt-d" } }, false)
local move_backward = rt._debug_edit_keys("foo\nbar", 4, { { key = "alt-b" } }, false)
local move_forward = rt._debug_edit_keys("foo\nbar", 3, { { key = "alt-f" } }, false)
local nbsp = rt._debug_edit_keys("foo bar", 8, { { key = "ctrl-w" } }, false)
local cjk_first = rt._debug_edit_keys("你好世界 test", 0, { { key = "alt-f" } }, false)
local cjk_second = rt._debug_edit_keys("你好世界 test", cjk_first.cursor, { { key = "alt-f" } }, false)
local ideographic = rt._debug_edit_keys("foo　bar", 9, { { key = "ctrl-w" } }, false)
local emoji_forward = rt._debug_edit_keys("foo👍bar", 0, { { key = "alt-f" } }, false)
local emoji_delete = rt._debug_edit_keys("foo👍bar", 10, { { key = "ctrl-w" } }, false)

return table.concat({
  backward.input,
  tostring(backward.cursor),
  forward.input,
  tostring(forward.cursor),
  tostring(move_backward.cursor),
  tostring(move_forward.cursor),
  nbsp.input,
  tostring(nbsp.cursor),
  tostring(cjk_first.cursor),
  tostring(cjk_second.cursor),
  ideographic.input,
  tostring(ideographic.cursor),
  tostring(emoji_forward.cursor),
  emoji_delete.input,
}, "|")
