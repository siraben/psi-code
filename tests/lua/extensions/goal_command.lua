--[==[psi-test
expect = "start|active|resume|edit|complete|cleared|tools"
]==]
local commands = require("psi.slash_commands")
local session = require("psi.session_manager")
local tui = require("psi.tui_status")

local path = TMP .. "/goal-command.jsonl"
psi.session_set_path(path)

local start = commands.handle("/goal Ship café support")
local status = tui.status_line({ model = "m", busy = false, scroll = 0 })
commands.handle("/goal pause")
local resume = commands.handle("/goal resume")
local edit = commands.handle("/goal edit Ship complete café support")

local completed = psi.tool_call("update_goal", { status = "complete" })
psi.events.emit("tool-results-persisted", { count = 1 })
local summary = commands.handle("/goal")
commands.handle("/goal clear")
local cleared = commands.handle("/goal")

local tools = psi.tools.find("create_goal")
  and psi.tools.find("get_goal")
  and psi.tools.find("update_goal")

return table.concat({
  start.kind == "expand" and start.payload == "Ship café support" and "start" or "bad",
  status:find("Pursuing goal", 1, true) and "active" or "bad",
  resume.kind == "expand" and "resume" or "bad",
  edit.kind == "expand" and edit.payload:find("Ship complete café support", 1, true) and "edit"
    or "bad",
  completed.ok and summary.payload:find("Goal complete", 1, true) and "complete" or "bad",
  cleared.payload:find("No goal is currently set", 1, true) and "cleared" or "bad",
  tools and "tools" or "bad",
}, "|")
