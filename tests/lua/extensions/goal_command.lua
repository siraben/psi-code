--[==[psi-test
expect = "set|prompt|status|resume|completed|hidden|cleared"
]==]
local commands = require("psi.slash_commands")
local prompt = require("psi.prompt")
local session = require("psi.session_manager")
local tui = require("psi.tui_status")

local path = TMP .. "/goal-command.jsonl"
psi.session_set_path(path)

local set = commands.handle("/goal set Ship café support")
local injected = prompt.system_prompt():find("<active_goal>\nShip café support", 1, true) ~= nil
local status = tui.status_line({ model = "m", busy = false, scroll = 0 })

psi.session_clear()
session.reset_entry_chain()
assert(session.load(path))
local resumed = commands.handle("/goal")
local completed = commands.handle("/goal complete")
local hidden = prompt.system_prompt():find("<active_goal>", 1, true) == nil
commands.handle("/goal clear")
local cleared = commands.handle("/goal show")

return table.concat({
  set.payload:find("goal set", 1, true) and "set" or "bad",
  injected and "prompt" or "bad",
  status:find("goal:Ship café support", 1, true) and "status" or "bad",
  resumed.payload == "goal (active): Ship café support" and "resume" or "bad",
  completed.payload:find("goal completed", 1, true) and "completed" or "bad",
  hidden and "hidden" or "bad",
  cleared.payload == "no goal set" and "cleared" or "bad",
}, "|")
