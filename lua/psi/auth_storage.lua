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
  local ok = psi.file_write(path, psi.json_encode(data or {}))
  if not ok then
    return false, "could not write " .. path
  end
  if psi.process_run_argv then
    local chmod = psi.process_run_argv({ "chmod", "600", path })
    if not chmod or chmod.status ~= 0 then
      os.remove(path)
      return false, "could not secure " .. path
    end
  else
    os.remove(path)
    return false, "could not secure " .. path
  end
  return true
end

function M.load()
  return read_all()
end

function M.get(provider)
  return read_all()[provider]
end

function M.set(provider, credential)
  local data = read_all()
  data[provider] = credential
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

return M
