--[[psi-test
expect = "medium|xhigh|off|true|xhigh|xhigh"
]]
local a = require("psi.agent_session")
local openai = { provider="openai-codex", id="gpt-5.5", reasoning=true }
local fallback = a.thinking_level_for(openai, nil, nil)
local explicit = a.thinking_level_for(openai, "xhigh", nil)
local off = a.thinking_level_for(openai, nil, "none")
local ok, set = a.set_thinking_level("xhigh", "openai-codex/gpt-5.5")
local current = a.current_reasoning_effort("low")
return fallback .. "|" .. explicit .. "|" .. off .. "|" .. tostring(ok) .. "|"
  .. tostring(set) .. "|" .. tostring(current)
