--[==[psi-test
expect = "hello|1||0|hello |hello||abc|one two three|two three|line1\nline2\nline3|first||abc|/he|current|0|a|reverse-empty|Ctrl-Y|Alt-Y|Ctrl--"
]==]
local kb = require("psi.keybindings")
local rt = require("psi.tui_runtime")

local function chars(text)
  local events = {}
  for i = 1, #text do
    events[#events + 1] = { key = "text", text = text:sub(i, i) }
  end
  return events
end

local word_once_events = chars("hello world")
word_once_events[#word_once_events + 1] = { key = "ctrl--" }
local word_once = rt._debug_edit_keys("", 0, word_once_events, false)

local word_twice_events = chars("hello world")
word_twice_events[#word_twice_events + 1] = { key = "ctrl--" }
word_twice_events[#word_twice_events + 1] = { key = "ctrl--" }
local word_twice = rt._debug_edit_keys("", 0, word_twice_events, false)

local spaces_events = chars("hello  ")
spaces_events[#spaces_events + 1] = { key = "ctrl--" }
local spaces = rt._debug_edit_keys("", 0, spaces_events, false)

local newline_events = chars("hello")
newline_events[#newline_events + 1] = { key = "shift-enter" }
for _, event in ipairs(chars("world")) do
  newline_events[#newline_events + 1] = event
end
newline_events[#newline_events + 1] = { key = "ctrl--" }
newline_events[#newline_events + 1] = { key = "ctrl--" }
local newline = rt._debug_edit_keys("", 0, newline_events, false)

local deleted = rt._debug_edit_keys("abc", 3, {
  { key = "backspace" },
  { key = "ctrl--" },
}, false)

local accumulated = rt._debug_edit_keys("one two three", 13, {
  { key = "ctrl-w" },
  { key = "ctrl-w" },
  { key = "ctrl-y" },
}, false)

local multiline = rt._debug_edit_keys("line1\nline2\nline3", 17, {
  { key = "ctrl-u" },
  { key = "ctrl-u" },
  { key = "ctrl-u" },
  { key = "ctrl-u" },
  { key = "ctrl-u" },
  { key = "ctrl-y" },
}, false)

local cycle_events = {}
for _, text in ipairs({ "first", "second", "third" }) do
  for _, event in ipairs(chars(text)) do
    cycle_events[#cycle_events + 1] = event
  end
  cycle_events[#cycle_events + 1] = { key = "ctrl-w" }
end
cycle_events[#cycle_events + 1] = { key = "ctrl-y" }
cycle_events[#cycle_events + 1] = { key = "alt-y" }
cycle_events[#cycle_events + 1] = { key = "alt-y" }
local cycled = rt._debug_edit_keys("", 0, cycle_events, false)

local yank_undo = rt._debug_edit_keys("hello ", 6, {
  { key = "ctrl-w" },
  { key = "ctrl-y" },
  { key = "ctrl--" },
}, false)

local paste_undo = rt._debug_edit_keys("abc", 1, {
  { key = "paste-start" },
  { key = "text", text = "X" },
  { key = "enter" },
  { key = "text", text = "Y" },
  { key = "paste-end" },
  { key = "ctrl--" },
}, false)

local completion_undo = rt._debug_edit_keys("/he", 3, {
  { key = "tab" },
  { key = "ctrl--" },
}, false)

local history_undo = rt._debug_edit_keys("current", 2, {
  { key = "up" },
  { key = "up" },
  { key = "ctrl--" },
}, false, { prompt_history = { "first", "second" } })

local unicode_space_undo = rt._debug_edit_keys("", 0, {
  { key = "text", text = "a" },
  { key = "text", text = "\u{00a0}" },
  { key = "text", text = "b" },
  { key = "ctrl--" },
}, false)

local reverse_search_undo = rt._debug_edit_keys("", 0, {
  { key = "ctrl-r" },
  { key = "ctrl--" },
}, false, { prompt_history = { "first", "second" } })

return table.concat({
  word_once.input,
  tostring(word_once.editor_undo_count),
  word_twice.input,
  tostring(word_twice.editor_undo_count),
  spaces.input,
  newline.input,
  yank_undo.input,
  paste_undo.input,
  accumulated.input,
  (accumulated.editor_kill_ring or {})[#(accumulated.editor_kill_ring or {})] or "",
  multiline.input,
  cycled.input,
  yank_undo.input,
  deleted.input,
  completion_undo.input,
  history_undo.input,
  tostring(history_undo.cursor),
  unicode_space_undo.input,
  reverse_search_undo.input == "" and "reverse-empty" or reverse_search_undo.input,
  kb.display("tui.editor.yank"),
  kb.display("tui.editor.yankPop"),
  kb.display("tui.editor.undo"),
}, "|")
