-- psi.openrouter_models: lazy OpenRouter model metadata cache.
--
-- Metadata is loaded from a JSON cache first. If a requested model is
-- missing, the cache is refreshed from OpenRouter's /models endpoint
-- and written back as JSON for future sessions.

local prelude = require("psi.prelude")

local M = {}

local API_URL = "https://openrouter.ai/api/v1/models"
local cache = nil
local fetched = false

local function cache_path()
  local override = os.getenv("PSI_OPENROUTER_MODELS_CACHE")
  if override and override ~= "" then
    return override
  end
  local xdg = os.getenv("XDG_CACHE_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/psi/openrouter_models.json"
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return home .. "/.cache/psi/openrouter_models.json"
  end
  return nil
end

local function decode_json(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  return prelude.safe_json_decode(text, nil)
end

local function model_input(model)
  local arch = type(model.architecture) == "table" and model.architecture or {}
  local modality = type(arch.modality) == "string" and arch.modality:lower() or ""
  local input = { "text" }
  if modality:find("image", 1, true) then
    input[#input + 1] = "image"
  end
  return input
end

local function has_param(model, name)
  local params = model.supported_parameters
  if type(params) ~= "table" then
    return false
  end
  for _, param in ipairs(params) do
    if param == name then
      return true
    end
  end
  return false
end

local function normalize_payload(payload)
  local out = {}
  local rows = type(payload) == "table" and payload.data or nil
  if type(rows) ~= "table" then
    return out
  end
  for _, model in ipairs(rows) do
    local id = model.id
    local top = type(model.top_provider) == "table" and model.top_provider or {}
    local context_window = tonumber(model.context_length) or tonumber(top.context_length)
    local max_output = tonumber(top.max_completion_tokens)
    if type(id) == "string" and id ~= "" and context_window and context_window > 0 then
      out[id] = {
        context_window = context_window,
        max_output_tokens = max_output and max_output > 0 and max_output or nil,
        reasoning = has_param(model, "reasoning") or has_param(model, "include_reasoning"),
        supports_tool_use = has_param(model, "tools"),
        input = model_input(model),
      }
    end
  end
  if out.auto == nil then
    out.auto = {
      context_window = 2000000,
      max_output_tokens = 30000,
      reasoning = true,
      supports_tool_use = true,
      input = { "text", "image" },
    }
  end
  return out
end

local function load_cache()
  if cache ~= nil then
    return cache
  end
  cache = {}
  local path = cache_path()
  if path then
    local parsed = decode_json(psi.read_file(path))
    if type(parsed) == "table" then
      cache = parsed
    end
  end
  return cache
end

local function save_cache()
  local path = cache_path()
  if not path then
    return false
  end
  if not psi.mkdir_parent(path) then
    return false
  end
  return psi.file_write(path, psi.json_encode(cache or {}))
end

local function refresh()
  fetched = true
  local status, body = psi.http_get(API_URL, { "Accept: application/json" })
  if status ~= 200 then
    return false
  end
  local payload = decode_json(body)
  if type(payload) ~= "table" then
    return false
  end
  cache = normalize_payload(payload)
  save_cache()
  return true
end

function M.model(slug, opts)
  if type(slug) ~= "string" or slug == "" then
    return nil
  end
  local models = load_cache()
  local meta = models[slug]
  if meta ~= nil then
    return meta
  end
  if
    not fetched
    and not (type(opts) == "table" and opts.refresh == false)
    and (slug == "auto" or slug:find("/", 1, true))
  then
    refresh()
    return cache and cache[slug] or nil
  end
  return nil
end

function M.all()
  load_cache()
  if not fetched then
    refresh()
  end
  return cache or {}
end

function M.cache_path()
  return cache_path()
end

function M._reset_for_tests()
  cache = nil
  fetched = false
end

return M
