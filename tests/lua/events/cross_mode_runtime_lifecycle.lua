--[==[psi-test
contains = "print:start:load,print:shutdown,repl:start:load,repl:shutdown,tui:start:load,tui:shutdown,compact:start:load,compact:shutdown|true|true|true|true"
files = [
  { path = "print.jsonl", text = "" },
  { path = "repl.jsonl", text = "" },
  { path = "tui.jsonl", text = "" },
  { path = "compact.jsonl", text = "" },
]
]==]
local events = {}
local active = ""
psi.events.on("session-start", function(payload)
  events[#events + 1] = active .. ":start:" .. tostring(payload.source)
end)
psi.events.on("session-shutdown", function()
  events[#events + 1] = active .. ":shutdown"
end)

local modes = require("psi.modes")

active = "print"
local print_ok = modes.run_print({
  session_file = TMP .. "/print.jsonl",
  payload = "lifecycle",
})

active = "repl"
local original_readline = psi.readline
psi.readline = function()
  return "/quit"
end
local repl_ok = modes.run_repl({
  session_file = TMP .. "/repl.jsonl",
})
psi.readline = original_readline

active = "tui"
local tui_ok, _, tui_runtime = require("psi.tui_runtime")._debug_bootstrap_session({
  session_file = TMP .. "/tui.jsonl",
})
tui_runtime:shutdown()

active = "compact"
local compact_ok = modes.run_compact({
  session_file = TMP .. "/compact.jsonl",
  keep_recent = 12,
})

return table.concat(events, ",")
  .. "|"
  .. tostring(print_ok)
  .. "|"
  .. tostring(repl_ok)
  .. "|"
  .. tostring(tui_ok)
  .. "|"
  .. tostring(compact_ok)
