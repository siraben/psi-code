--[==[psi-test
expect = "true|65536|true|16384|true|321"
]==]
local agent = require("psi.agent_session")
local moonshot = require("psi.providers.moonshot")

psi.session_clear()
agent.configure({ model = "moonshot/k3" })

local captured
moonshot.run_turn = function(opts)
  captured = opts
  return true, "ok"
end

local default_ok = agent.run_turn({ user_text = "default limit" })
local default_limit = captured and captured.max_tokens
agent.configure({ model = "moonshot/kimi-for-coding" })
local legacy_ok = agent.run_turn({ user_text = "legacy model limit" })
local legacy_limit = captured and captured.max_tokens
local override_ok = agent.run_turn({ user_text = "override", max_tokens = 321 })
local override_limit = captured and captured.max_tokens

return table.concat({
  tostring(default_ok),
  tostring(default_limit),
  tostring(legacy_ok),
  tostring(legacy_limit),
  tostring(override_ok),
  tostring(override_limit),
}, "|")
