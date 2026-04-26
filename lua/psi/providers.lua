-- psi.providers: small provider/model/API registry.
--
-- This keeps provider selection policy in Lua instead of scattering it
-- across the agent loop. It is intentionally compact: providers still
-- implement their own wire adapters, while this module records routing,
-- defaults, model metadata, and compatibility flags.

local M = {}

local providers = {}
local models = {}

local function copy_table(t)
  local out = {}
  for k, v in pairs(t or {}) do
    if type(v) == "table" then
      out[k] = copy_table(v)
    else
      out[k] = v
    end
  end
  return out
end

function M.register_provider(name, spec)
  if type(name) ~= "string" or name == "" then
    return false, "provider name is required"
  end
  spec = copy_table(spec or {})
  spec.name = name
  providers[name] = spec
  return true
end

function M.register_model(id, spec)
  if type(id) ~= "string" or id == "" then
    return false, "model id is required"
  end
  spec = copy_table(spec or {})
  spec.id = id
  models[id] = spec
  return true
end

function M.provider(name)
  return providers[name]
end

function M.model(id)
  local exact = models[id]
  if exact then
    return exact
  end
  if type(id) ~= "string" or id == "" then
    return nil
  end

  local slug = id
  local prefix = "openrouter/"
  if slug:sub(1, #prefix) == prefix then
    slug = slug:sub(#prefix + 1)
  end

  local ok, openrouter_models = pcall(require, "psi.openrouter_models")
  local meta = ok and openrouter_models and openrouter_models.model(slug)
  if type(meta) ~= "table" then
    return nil
  end

  local out = copy_table(meta)
  out.id = prefix .. slug
  out.provider = "openrouter"
  out.api = "openrouter-chat-completions"
  return out
end

function M.all_providers()
  local out = {}
  for name, spec in pairs(providers) do
    out[#out + 1] = { name = name, api = spec.api, default_model = spec.default_model }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function M.all_models()
  local out = {}
  local seen = {}
  for id, spec in pairs(models) do
    local item = copy_table(spec)
    item.id = id
    seen[id] = true
    out[#out + 1] = item
  end
  local ok, openrouter_models = pcall(require, "psi.openrouter_models")
  local openrouter_all = ok and openrouter_models and openrouter_models.all()
  if type(openrouter_all) == "table" then
    for slug, spec in pairs(openrouter_all) do
      local id = "openrouter/" .. slug
      if not seen[id] then
        local item = copy_table(spec)
        item.id = id
        item.provider = "openrouter"
        item.api = "openrouter-chat-completions"
        out[#out + 1] = item
      end
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

local function env(name, fallback)
  local v = os.getenv(name)
  if v and v ~= "" then
    return v
  end
  return fallback
end

local function canonical_id(provider_name, model_id)
  if type(provider_name) ~= "string" or provider_name == "" then
    return model_id
  end
  if type(model_id) ~= "string" or model_id == "" then
    return model_id
  end
  return provider_name .. "/" .. model_id
end

M.register_provider("anthropic", {
  api = "anthropic-messages",
  module = "psi.anthropic",
  model_env = "PSI_ANTHROPIC_MODEL",
  default_model = "claude-opus-4-7",
  compat = {
    supports_reasoning = true,
    supports_tool_use = true,
    thinking_format = "anthropic",
  },
})

M.register_provider("ollama", {
  api = "ollama-chat",
  module = "psi.ollama",
  model_env = "PSI_OLLAMA_MODEL",
  default_model = "llama3.1:latest",
  compat = {
    supports_tool_use = true,
    thinking_format = "openai-compatible",
  },
})

M.register_provider("openrouter", {
  api = "openrouter-chat-completions",
  module = "psi.openrouter",
  model_env = "PSI_OPENROUTER_MODEL",
  default_model = "google/gemini-3-flash-preview",
  compat = {
    supports_tool_use = true,
    supports_reasoning_effort = false,
    max_tokens_field = "max_tokens",
  },
})

M.register_model("anthropic/claude-opus-4-7", {
  provider = "anthropic",
  api = "anthropic-messages",
  context_window = 1000000,
  max_output_tokens = 128000,
  reasoning = true,
})

M.register_model("ollama/llama3.1:latest", {
  provider = "ollama",
  api = "ollama-chat",
  local_model = true,
})

M.register_model("openrouter/google/gemini-3-flash-preview", {
  provider = "openrouter",
  api = "openrouter-chat-completions",
  context_window = 1048576,
  max_output_tokens = 65536,
  reasoning = true,
  supports_tool_use = true,
})

function M.resolve_model(provider_name, requested)
  local p = providers[provider_name]
  if not p then
    return requested
  end
  if requested and requested ~= "" then
    return requested
  end
  local ok, settings = pcall(require, "psi.settings")
  if ok and settings then
    local configured = settings.get("defaults.model", nil)
    if type(configured) == "string" and configured ~= "" then
      local prefix = provider_name .. "/"
      if configured:sub(1, #prefix) == prefix then
        return configured:sub(#prefix + 1)
      end
      if settings.get("defaults.provider", nil) == provider_name then
        return configured
      end
    end
  end
  return env(p.model_env, p.default_model)
end

function M.resolve_route(model)
  if type(model) == "string" then
    local provider_name, rest = model:match("^([^/]+)/(.+)$")
    if provider_name and providers[provider_name] then
      return providers[provider_name], rest
    end
  end

  local env_provider = os.getenv("PSI_PROVIDER")
  if env_provider and providers[env_provider] then
    return providers[env_provider], model
  end

  local ok, settings = pcall(require, "psi.settings")
  if ok and settings then
    local configured_model = settings.get("defaults.model", nil)
    if (not model or model == "") and type(configured_model) == "string" then
      return M.resolve_route(configured_model)
    end
    local configured_provider = settings.get("defaults.provider", nil)
    if providers[configured_provider] then
      return providers[configured_provider], model
    end
  end

  return providers.anthropic, model
end

function M.resolve_descriptor(model)
  local spec, requested = M.resolve_route(model)
  if not spec then
    return nil
  end
  local real_model = M.resolve_model(spec.name, requested)
  local meta = M.model(canonical_id(spec.name, real_model)) or M.model(real_model) or {}
  local out = copy_table(meta)
  out.provider = spec.name
  out.api = out.api or spec.api
  out.id = real_model
  out.model = real_model
  out.ref = canonical_id(spec.name, real_model)
  return out
end

function M.load_provider(spec)
  if not spec or not spec.module then
    return nil
  end
  return require(spec.module)
end

return M
