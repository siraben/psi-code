--[==[psi-test
expect = "kimi=true|none=false|anthropic=true"
]==]
-- Moonshot auth resolves from KIMI_API_KEY; Anthropic from ANTHROPIC_API_KEY.
local moonshot = require("psi.providers.moonshot")
local anthropic = require("psi.providers.anthropic")

local real_getenv = os.getenv
local env = {}
os.getenv = function(name)
  return env[name]
end

env.KIMI_API_KEY = "sk-kimi-test"
local kimi = moonshot.has_auth()

env.KIMI_API_KEY = nil
local none = moonshot.has_auth()

env.ANTHROPIC_API_KEY = "sk-ant-test"
local anth = anthropic.has_auth()

os.getenv = real_getenv

return table.concat({
  "kimi=" .. tostring(kimi),
  "none=" .. tostring(none),
  "anthropic=" .. tostring(anth),
}, "|")
