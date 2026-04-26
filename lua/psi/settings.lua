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
  local home = os.getenv("HOME")
  if home and home ~= "" then
    merge(out, read_json(prelude.path_join(home, ".config/psi/settings.json")))
  end
  merge(out, read_json(".psi/settings.json"))
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

return M
