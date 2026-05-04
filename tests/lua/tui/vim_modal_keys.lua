--[[psi-test
expect = "normal|14|beta|alpha betabeta gamma|-|a\nb|0|normal|  aa!\nbb|  xaa|aa\nx\nbb|aa\nx\nbb|0||insert|true|line|true|xaa\nxbb\ncc|aax\nbbx\ncc|abort"
]]
local rt = require("psi.tui_runtime")
local tui = require("psi.tui_status")
require("psi.extensions.vim_keybindings").enable(psi)
local function text(c) return {key="text", text=c} end
local s = rt._debug_edit_keys("alpha beta gamma", 0, {
  {key="escape"}, text("w"), text("v"), text("l"), text("l"), text("l"), text("l"), text("y"), text("p")
})
local b = rt._debug_edit_keys("aa\nbb\ncc", 0, {
  {key="escape"}, {key="ctrl-v"}, text("j"), text("y")
})
local g = rt._debug_edit_keys("", 0, {
  {key="escape"}, {key="ctrl-u"}, text("g"), text("g"), text("G")
})
local a = rt._debug_edit_keys("  aa\nbb", 0, {
  {key="escape"}, text("A"), text("!"), {key="escape"}
})
local i = rt._debug_edit_keys("  aa", 4, {
  {key="escape"}, text("I"), text("x"), {key="escape"}
})
local o = rt._debug_edit_keys("aa\nbb", 0, {
  {key="escape"}, text("o"), text("x"), {key="escape"}
})
local O = rt._debug_edit_keys("aa\nbb", 3, {
  {key="escape"}, text("O"), text("x"), {key="escape"}
})
local line = rt._debug_edit_keys("  aa\nbb", 0, {
  {key="escape"}, text("$"), text("^"), {key="ctrl-e"}, {key="ctrl-a"}
})
local clear = rt._debug_edit_keys("abc", 2, {
  {key="escape"}, {key="ctrl-c"}
})
local visual = rt._debug_edit_keys("abc", 0, {
  {key="escape"}, text("v"), text("l")
})
local line_visual = rt._debug_edit_keys("alpha\n\nbeta", 6, {
  {key="escape"}, text("V")
})
local block_insert = rt._debug_edit_keys("aa\nbb\ncc", 0, {
  {key="escape"}, {key="ctrl-v"}, text("j"), text("I"), text("x"), {key="escape"}
})
local block_append = rt._debug_edit_keys("aa\nbb\ncc", 0, {
  {key="escape"}, {key="ctrl-v"}, text("l"), text("j"), text("A"), text("x"), {key="escape"}
})
local interrupt = tui.handle_key({key="ctrl-g", busy=true, editor_mode="normal", input_length=1})
return table.concat({
  s.editor_mode, tostring(s.cursor), s.clipboard, s.input,
  b.selection_kind or "-", b.clipboard,
  tostring(g.scroll_offset), g.editor_mode,
  a.input, i.input, o.input, O.input,
  tostring(line.cursor), clear.input, clear.editor_mode,
  tostring((visual.rendered[1] or ""):find("\27%[7m") ~= nil),
  line_visual.selection_kind or "-",
  tostring((line_visual.rendered[2] or ""):find("\27%[7m") ~= nil),
  block_insert.input,
  block_append.input,
  interrupt and interrupt.action or "-"
}, "|")
