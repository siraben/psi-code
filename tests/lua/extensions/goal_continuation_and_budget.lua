--[==[psi-test
expect = "continued|limited|25|0"
]==]
local commands = require("psi.slash_commands")
local control = require("psi.agent_control")
local goal = require("psi.extensions.goal")

psi.session_set_path(TMP .. "/goal-continuation.jsonl")
commands.handle("/goal Keep going")
psi.events.emit("after-provider-response", {
  stop_reason = "end_turn",
  usage = { input_tokens = 4, output_tokens = 6 },
})
local continued = control.append_internal_follow_ups() == 1

commands.handle("/goal clear")
local created = psi.tool_call("create_goal", { objective = "Budgeted", token_budget = 25 })
psi.events.emit("tool-results-persisted", { count = 1 })
psi.events.emit("after-provider-response", {
  stop_reason = "stop",
  usage = { input_tokens = 20, output_tokens = 10 },
})
local state = goal._read_state(psi)
local no_continuation = control.append_internal_follow_ups()

return table.concat({
  continued and "continued" or "bad",
  state.status == "budget_limited" and "limited" or "bad",
  tostring(created.goal.token_budget),
  tostring(no_continuation),
}, "|")
