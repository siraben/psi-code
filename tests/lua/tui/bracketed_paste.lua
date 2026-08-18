--[==[psi-test
expect = "first\nsecond\nthird|18|1|alpha\nbeta\ngamma|abX\nY|5|hi|1"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")

-- A bracketed paste lands in the editor as one multi-line buffer;
-- the embedded newlines never submit per line.
local paste = rt._debug_edit_keys("", 0, {
  { key = "paste-start" },
  { key = "text", text = "first" },
  { key = "enter" },
  { key = "text", text = "second" },
  { key = "enter" },
  { key = "text", text = "third" },
  { key = "paste-end" },
}, false)

-- After the paste, a single Enter submits the whole buffer once.
agent.clear_queues()
local submit = rt._debug_edit_keys("", 0, {
  { key = "paste-start" },
  { key = "text", text = "alpha" },
  { key = "enter" },
  { key = "text", text = "beta" },
  { key = "enter" },
  { key = "text", text = "gamma" },
  { key = "paste-end" },
  { key = "enter" },
}, false, { busy = true, busy_kind = "agent" })
local queued = agent.pending_message(1)
local queued_count = agent.pending_message_count()

-- A paste splices into existing input at the cursor.
local spliced = rt._debug_edit_keys("ab", 2, {
  { key = "paste-start" },
  { key = "text", text = "X" },
  { key = "enter" },
  { key = "text", text = "Y" },
  { key = "paste-end" },
}, false)

-- A dropped end marker flushes what arrived and leaves the editor usable.
local unterminated = rt._debug_edit_keys("", 0, {
  { key = "paste-start" },
  { key = "text", text = "hi" },
  { key = "left" },
}, false)

agent.clear_queues()

return table.concat({
  paste.input,
  tostring(paste.cursor),
  tostring(queued_count),
  tostring(queued and queued.text),
  spliced.input,
  tostring(spliced.cursor),
  unterminated.input,
  tostring(unterminated.cursor),
}, "|")
