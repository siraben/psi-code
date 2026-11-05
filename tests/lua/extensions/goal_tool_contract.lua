--[==[psi-test
expect = "active|refused|blocked|4000"
]==]
local goal = require("psi.extensions.goal")
psi.session_set_path(TMP .. "/goal-tools.jsonl")

local created = psi.tool_call("create_goal", { objective = "Do the work" })
psi.events.emit("tool-results-persisted", { count = 1 })
local refused = psi.tool_call("create_goal", { objective = "Replace unfinished" })
local blocked = psi.tool_call("update_goal", { status = "blocked" })
psi.events.emit("tool-results-persisted", { count = 1 })
local too_long = psi.tool_call("create_goal", { objective = string.rep("é", 4001) })

return table.concat({
  created.goal.status,
  not refused.ok and "refused" or "bad",
  blocked.goal.status,
  not too_long.ok and too_long.error:find("4000", 1, true) and "4000" or "bad",
}, "|")
