-- psi.auth_storage: file-backed provider credentials.
--
-- The on-disk shape intentionally matches pi-mono's auth.json:
-- {
--   "provider": { "type": "api_key", "key": "..." },
--   "openai-codex": {
--     "type": "oauth",
--     "access": "...",
--     "refresh": "...",
--     "expires": 1770000000000,
--     "accountId": "..."
--   }
-- }

local prelude = require("psi.prelude")
local credential = require("psi.credential")

local M = {}

local function config_dir()
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return prelude.path_join(prelude.path_join(home, ".config"), "psi")
  end
  return ".psi"
end

function M.path()
  local override = os.getenv("PSI_AUTH_FILE")
  if override and override ~= "" then
    return override
  end
  return prelude.path_join(config_dir(), "auth.json")
end

local function read_all()
  local path = M.path()
  if not psi.file_exists(path) then
    return {}
  end
  local ok, content = pcall(psi.read_file, path)
  if not ok or type(content) ~= "string" then
    return nil, "could not read " .. path .. "; leaving it unchanged"
  end
  local parsed = prelude.safe_json_decode(content, nil)
  if type(parsed) ~= "table" then
    return nil, "could not parse " .. path .. "; leaving it unchanged"
  end
  for provider, entry in pairs(parsed) do
    if type(provider) ~= "string" or type(entry) ~= "table" then
      return nil, "invalid credential data in " .. path .. "; leaving it unchanged"
    end
  end
  return parsed
end

local function write_all(data)
  local path = M.path()
  if not psi.mkdir_parent(path) then
    return false, "could not create auth directory"
  end
  -- 0600 from first open + atomic rename: credentials never sit on
  -- disk world-readable, and there's no failed-chmod cleanup window.
  local encoded_ok, encoded = pcall(psi.json_encode, data or {})
  if not encoded_ok or type(encoded) ~= "string" then
    return false, "could not encode credentials"
  end
  local ok = psi.file_write_secure(path, encoded)
  if not ok then
    return false, "could not write " .. path
  end
  return true
end

function M.load()
  return read_all()
end

function M.get(provider)
  local data, err = read_all()
  if not data then
    return nil, err
  end
  return data[provider]
end

function M.set(provider, entry)
  if type(provider) ~= "string" or provider == "" or type(entry) ~= "table" then
    return false, "provider and credential entry are required"
  end
  local data, err = read_all()
  if not data then
    return false, err
  end
  data[provider] = entry
  return write_all(data)
end

function M.remove(provider)
  if type(provider) ~= "string" or provider == "" then
    return false, "provider is required"
  end
  local data, err = read_all()
  if not data then
    return false, err
  end
  local removed = data[provider]
  if removed == nil then
    return false, "no stored credential for " .. provider
  end
  data[provider] = nil
  local ok, write_err = write_all(data)
  if not ok then
    return false, write_err
  end
  return true, removed
end

-- List stored credential metadata without resolving API-key references or
-- exposing secret fields. This is the source for /logout selection.
function M.list()
  local data, err = read_all()
  if not data then
    return nil, err
  end
  local out = {}
  for provider, entry in pairs(data) do
    out[#out + 1] = {
      provider = provider,
      type = type(entry.type) == "string" and entry.type or "unknown",
    }
  end
  table.sort(out, function(a, b)
    return a.provider < b.provider
  end)
  return out
end

function M.get_api_key(provider)
  local entry = M.get(provider)
  if type(entry) ~= "table" then
    return nil
  end
  if entry.type == "api_key" and type(entry.key) == "string" then
    return entry.key, entry
  end
  if entry.type == "oauth" and type(entry.access) == "string" then
    return entry.access, entry
  end
  return nil, entry
end

-- Does the auth file hold an api_key entry for `provider`? A presence
-- check only: it never runs a `!shell-command` or reads the environment,
-- so callers can use it in an auth gate without side effects.
function M.has_api_key_entry(provider)
  local entry = M.get(provider)
  return type(entry) == "table"
    and entry.type == "api_key"
    and type(entry.key) == "string"
    and entry.key ~= ""
end

-- Resolve the effective API key for `provider`, giving the auth file
-- precedence over the environment variable (matching pi). The auth-file
-- value is run through psi.credential so `$VAR`, `${VAR}`, and
-- `!shell-command` forms are expanded. Returns (key, source) where
-- source is "auth-file" or "env", or nil when neither is configured.
function M.resolve_api_key(provider, env_var)
  if M.has_api_key_entry(provider) then
    local entry = M.get(provider)
    local resolved = credential.resolve(entry.key)
    if resolved and resolved ~= "" then
      return resolved, "auth-file"
    end
  end
  if env_var then
    local env = os.getenv(env_var)
    if env and env ~= "" then
      return env, "env"
    end
  end
  return nil
end

-- Presence gate for api-key providers: an auth-file entry (not yet
-- resolved) or a set environment variable. Avoids running credential
-- shell commands, so it is safe on the resolver's hot path.
function M.has_api_key(provider, env_var)
  if M.has_api_key_entry(provider) then
    return true
  end
  if env_var then
    local env = os.getenv(env_var)
    return env ~= nil and env ~= ""
  end
  return false
end

return M
