--[==[psi-test
expect = "Steering: steer now|Follow-up: follow later|↳ Alt-Up to edit all queued messages|session:-  model:claude-opus-4-8  thinking:medium  msg:0  busy…"
]==]
local agent = require("psi.agent_session")
local rt = require("psi.tui_runtime")
local status = require("psi.tui_status")
agent.clear_queues()
agent.queue_steering("steer now")
agent.queue_follow_up("follow later")
local lines = rt._debug_pending_queue_lines(80)
local footer = status.status_line({ busy = true, scroll = 0, show_queue_in_status = false })
return table.concat({
  require("psi.tui_text").strip_ansi(lines[2] or ""),
  require("psi.tui_text").strip_ansi(lines[3] or ""),
  require("psi.tui_text").strip_ansi(lines[4] or ""),
  footer,
}, "|")
