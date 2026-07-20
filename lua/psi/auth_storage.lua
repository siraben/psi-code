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
  -- Repair loose permissions on pre-existing files (e.g. copied from a
  -- backup or written by another tool): credentials must stay 0600.
  -- Best-effort; a failed chmod must not break the read.
  if psi.file_chmod then
    pcall(psi.file_chmod, path, tonumber("600", 8))
  end
  local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
  if type(parsed) == "table" then
    return parsed
  end
  return {}
end

local function write_all(data)
  local path = M.path()
  if not psi.mkdir_parent(path) then
    return false, "could not create auth directory"
  end
  -- 0600 from first open + atomic rename: credentials never sit on
  -- disk world-readable, and there's no failed-chmod cleanup window.
  local ok = psi.file_write_secure(path, psi.json_encode(data or {}))
  if not ok then
    return false, "could not write " .. path
  end
  return true
end

function M.load()
  return read_all()
end

function M.get(provider)
  return read_all()[provider]
end

function M.set(provider, entry)
  local data = read_all()
  data[provider] = entry
  return write_all(data)
end

function M.remove(provider)
  local data = read_all()
  data[provider] = nil
  return write_all(data)
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
