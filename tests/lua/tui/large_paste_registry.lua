--[==[psi-test
expect = "[paste #1 +11 lines]|[paste #2 1001 chars]|true|true|[paste #1 1001 chars]|true|0|true"
]==]
local paste = require("psi.tui_editor_paste")

local state = {
  input = "",
  cursor = 0,
  editor_pastes = {},
  editor_paste_counter = 0,
  editor_paste_revision = 0,
}
local lines = table.concat({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" }, "\n")
local chars = string.rep("$1%", 333) .. "xx"
local first = paste.compact(state, lines)
local second = paste.compact(state, chars)
state.input = first .. " " .. second
state.cursor = #state.input
local expanded = paste.expand(state, state.input)
local snapshot = paste.clone(state)

state.input = second
state.cursor = #state.input
paste.reconcile(state)
local compacted = state.input
local compacted_expands = paste.expand(state, compacted) == chars

paste.clear(state)
paste.restore(state, snapshot)
local restored = paste.expand(state, first .. " " .. second) == expanded

paste.clear(state)
local fake = paste.expand(state, "[paste #1 1001 chars]")
local fake_count = #paste.markers(state, fake)

local astral = paste.compact(state, string.rep("😀", 501))

return table.concat({
  first,
  second,
  tostring(expanded == (lines .. " " .. chars)),
  tostring(restored),
  compacted,
  tostring(compacted_expands),
  tostring(fake_count),
  tostring(astral:match("^%[paste #1 1002 chars%]$") ~= nil),
}, "|")
