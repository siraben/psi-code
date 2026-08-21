--[==[psi-test
expect = "inline-lines|[paste #1 +11 lines]|inline-chars|[paste #1 1001 chars]|true|true|0|21|ab|1||before |7| [paste #1 1001 chars]|true|1|paste #1 1001 chars]|1|0|true|true"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")

local function paste(input, cursor, text, tail, options)
  local events = {
    { key = "paste-start" },
    { key = "text", text = text },
    { key = "paste-end" },
  }
  for _, event in ipairs(tail or {}) do
    events[#events + 1] = event
  end
  return rt._debug_edit_keys(input, cursor, events, false, options)
end

local ten_lines = table.concat({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }, "\n")
local eleven_lines = ten_lines .. "\n11"
local inline_lines = paste("", 0, ten_lines)
local large_lines = paste("", 0, eleven_lines)
local inline_chars = paste("", 0, string.rep("x", 1000))
local large_chars = paste("", 0, string.rep("x", 1001))

local special = "head $1 %q\n" .. string.rep("z", 1001)
local lossless = paste("", 0, special)

local left = paste("", 0, string.rep("x", 1001), { { key = "left" } })
local right = paste("", 0, string.rep("x", 1001), {
  { key = "left" },
  { key = "right" },
})
local backspace = paste("ab", 1, string.rep("x", 1001), { { key = "backspace" } })
local forward = paste("", 0, string.rep("x", 1001), {
  { key = "home" },
  { key = "delete" },
})
local word_back = paste("before ", 7, string.rep("x", 1001), { { key = "alt-backspace" } })
local word_left = paste("before ", 7, string.rep("x", 1001), { { key = "alt-left" } })

local two = rt._debug_edit_keys("", 0, {
  { key = "paste-start" },
  { key = "text", text = string.rep("a", 1001) },
  { key = "paste-end" },
  { key = "text", text = " " },
  { key = "paste-start" },
  { key = "text", text = string.rep("b", 1001) },
  { key = "paste-end" },
  { key = "home" },
  { key = "delete" },
}, false)

local fake_move = rt._debug_edit_keys("[paste #1 1001 chars]", 0, { { key = "right" } }, false)
local fake_delete = rt._debug_edit_keys("[paste #1 1001 chars]", 0, { { key = "delete" } }, false)

local wrapped = paste("prefixxx ", 9, string.rep("w", 1001), {}, { width = 25 })
local wrapped_whole = false
for _, line in ipairs(wrapped.rendered) do
  if line:find("[paste #1 1001 chars]", 1, true) ~= nil then
    wrapped_whole = true
  end
end

agent.clear_queues()
local submitted_text = "alpha\n" .. string.rep("s", 1001)
paste("", 0, submitted_text, { { key = "enter" } }, { busy = true, busy_kind = "agent" })
local queued = agent.pending_message(1)
agent.clear_queues()

return table.concat({
  inline_lines.input == ten_lines and "inline-lines" or "bad-inline-lines",
  large_lines.input,
  inline_chars.input == string.rep("x", 1000) and "inline-chars" or "bad-inline-chars",
  large_chars.input,
  tostring(lossless.expanded_input == special),
  tostring(large_lines.expanded_input == eleven_lines),
  tostring(left.cursor),
  tostring(right.cursor),
  backspace.input,
  tostring(backspace.cursor),
  forward.input,
  word_back.input,
  tostring(word_left.cursor),
  two.input,
  tostring(two.expanded_input == (" " .. string.rep("b", 1001))),
  tostring(two.paste_count),
  fake_delete.input,
  tostring(fake_move.cursor),
  tostring(agent.pending_message_count()),
  tostring(queued ~= nil and queued.text == submitted_text),
  tostring(wrapped_whole),
}, "|")
