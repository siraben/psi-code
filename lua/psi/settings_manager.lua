-- psi.settings: small layered JSON settings loader.
--
-- Layers, lowest to highest precedence:
--   ~/.config/psi/settings.json
--   ./.psi/settings.json
--
-- Environment variables still win where provider modules already use
-- them; settings only provide repo/global defaults.

local prelude = require("psi.prelude")

local M = {}

local cached = nil

local function config_dir()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return prelude.path_join(xdg, "psi")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return prelude.path_join(home, ".config/psi")
  end
  return nil
end

local function global_path()
  local dir = config_dir()
  return dir and prelude.path_join(dir, "settings.json") or nil
end

local function merge(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function read_json(path)
  if not psi.file_exists(path) then
    return nil
  end
  local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
  if type(parsed) == "table" then
    return parsed
  end
  return nil
end

function M.reload()
  local out = {}
  local path = global_path()
  if path then
    merge(out, read_json(path))
  end
  -- Repo-local settings can reroute providers or inject terminal
  -- sequences, so they only apply to trusted directories.
  if psi.project_trusted then
    merge(out, read_json(".psi/settings.json"))
  end
  cached = out
  return cached
end

function M.all()
  return cached or M.reload()
end

function M.get(path, default)
  local cur = M.all()
  for part in tostring(path):gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return default
    end
    cur = cur[part]
  end
  if cur == nil then
    return default
  end
  return cur
end

local function set_path(root, path, value)
  local parts = {}
  for part in tostring(path or ""):gmatch("[^.]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return false, "setting path must not be empty"
  end
  local parent = root
  for i = 1, #parts - 1 do
    local part = parts[i]
    if type(parent[part]) ~= "table" then
      parent[part] = {}
    end
    parent = parent[part]
  end
  parent[parts[#parts]] = value
  return true
end

-- Persist a setting in the user-level file. Project settings remain a
-- higher-precedence read layer, matching pi's global settings mutations.
function M.set_global(path, value)
  local file = global_path()
  if not file then
    return false, "no user configuration directory"
  end
  local global = read_json(file) or {}
  local ok, err = set_path(global, path, value)
  if not ok then
    return false, err
  end
  if not psi.mkdir_parent(file) then
    return false, "failed to create settings directory"
  end
  local encoded = psi.json_encode(global) .. "\n"
  local mode = type(psi.file_mode) == "function" and psi.file_mode(file) or nil
  mode = tonumber(mode) or 384 -- 0600
  if type(psi.file_write_atomic) == "function" then
    ok = psi.file_write_atomic(file, encoded, mode)
  else
    ok = psi.file_write(file, encoded)
  end
  if not ok then
    return false, "failed to write " .. file
  end
  M.reload()
  return true
end

function M.global_path()
  return global_path()
end

return M
