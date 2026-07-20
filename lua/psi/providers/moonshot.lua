-- psi.moonshot: Moonshot / Kimi For Coding provider. Kimi For Coding speaks the
-- Anthropic Messages wire format at https://api.kimi.com/coding, so this is a
-- thin flavour over psi.providers.anthropic supplying only the endpoint, Bearer
-- auth, and model defaults. Route with the "moonshot/" model prefix.

local anthropic = require("psi.providers.anthropic")

local M = {}

local FLAVOR = {
  provider_name = "moonshot",
  api_name = "moonshot-messages",
  label = "Kimi",
  api_key_envs = { "KIMI_API_KEY" },
  key_missing_msg = "KIMI_API_KEY is not set",
  model_env = "PSI_MOONSHOT_MODEL",
  model_default = "k3",
  base_url_env = "PSI_MOONSHOT_BASE_URL",
  base_url_default = "https://api.kimi.com/coding/",
  auth_header = function(api_key)
    return "Authorization: Bearer " .. api_key
  end,
  extra_headers = { "User-Agent: KimiCLI/1.5" },
  allow_bridge = false,
}

M.FLAVOR = FLAVOR

function M.run_turn(opts)
  return anthropic.run_turn(opts, FLAVOR)
end

function M.complete_text(opts)
  return anthropic.complete_text(opts, FLAVOR)
end

function M.has_auth()
  return anthropic.has_auth(FLAVOR)
end

return M
