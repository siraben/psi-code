--[==[psi-test
expect = "explicit=openai-codex|noauth_default=anthropic|authed_default=openai-codex|no_provider_authed=anthropic|ollama_not_implicit=anthropic"
]==]
-- Regression: settings.defaults.provider = openai-codex must not route
-- implicit/background resolutions to an unauthenticated codex provider.
local reg = require("psi.api_registry")

local auth = { ["openai-codex"] = false, ["anthropic"] = true, ["openrouter"] = false, ["ollama"] = false }
reg.provider_has_auth = function(name)
  return auth[name] == true
end

local settings = require("psi.settings_manager")
local orig_get = settings.get
settings.get = function(key, default)
  if key == "defaults.provider" then
    return "openai-codex"
  end
  if key == "defaults.model" then
    return nil
  end
  return orig_get(key, default)
end

local results = {}

-- Explicit provider/model is always honoured, even without auth.
local e = reg.resolve_route("openai-codex/gpt-5.5")
results[#results + 1] = "explicit=" .. (e and e.name or "nil")

-- Empty model + codex default that lacks auth -> first authed provider.
local d = reg.resolve_route("")
results[#results + 1] = "noauth_default=" .. (d and d.name or "nil")

-- If the codex default DOES have auth, honour it.
auth["openai-codex"] = true
local d2 = reg.resolve_route("")
results[#results + 1] = "authed_default=" .. (d2 and d2.name or "nil")

-- If nothing is authed, fall back to the deterministic default (anthropic).
for k in pairs(auth) do
  auth[k] = false
end
local d3 = reg.resolve_route("")
results[#results + 1] = "no_provider_authed=" .. (d3 and d3.name or "nil")

-- ollama has_auth() is always true, but it must never be the *implicit*
-- default: an unconfigured cloud environment still resolves to anthropic.
auth["ollama"] = true
local d4 = reg.resolve_route("")
results[#results + 1] = "ollama_not_implicit=" .. (d4 and d4.name or "nil")

settings.get = orig_get
return table.concat(results, "|")
