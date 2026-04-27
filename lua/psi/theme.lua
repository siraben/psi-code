local ansi = require("psi.ansi")
local settings = require("psi.settings")

local M = {}

local registry = {}
local current_name = nil
local current_theme = nil

local DEFAULT_THEME_NAME = "midnight-ember"
local TUI_SLOTS = {
  "header",
  "accent",
  "text",
  "warning",
  "success",
  "error",
  "chrome",
}

local DEFAULT_THEME = {
  ansi = {
    ["31"] = "31",
    ["32"] = "32",
    ["33"] = "33",
    ["34"] = "34",
    ["36"] = "36",
    ["37"] = "37",
  },
  tui = {
    header = { fg = 111, bg = 234 },
    accent = { fg = 81, bg = 234 },
    text = { fg = 253, bg = 234 },
    warning = { fg = 223, bg = 234 },
    success = { fg = 150, bg = 234 },
    error = { fg = 210, bg = 234 },
    chrome = { fg = 245, bg = 234 },
  },
}

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, inner in pairs(value) do
    out[key] = deep_copy(inner)
  end
  return out
end

local function merge(dst, src)
  for key, value in pairs(src or {}) do
    if type(value) == "table" and type(dst[key]) == "table" then
      merge(dst[key], value)
    else
      dst[key] = deep_copy(value)
    end
  end
  return dst
end

local function normalize(theme)
  local merged = merge(deep_copy(DEFAULT_THEME), theme or {})
  for _, slot in ipairs(TUI_SLOTS) do
    local spec = merged.tui[slot] or {}
    merged.tui[slot] = {
      fg = tonumber(spec.fg) or -1,
      bg = tonumber(spec.bg) or -1,
    }
  end
  return merged
end

local function tui_payload(theme)
  local payload = { pairs = {} }
  for index, slot in ipairs(TUI_SLOTS) do
    local spec = theme.tui[slot] or {}
    payload.pairs[index] = {
      fg = tonumber(spec.fg) or -1,
      bg = tonumber(spec.bg) or -1,
    }
  end
  return payload
end

local function configured_name()
  local value = settings.get("theme.name", settings.get("tui.theme", nil))
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function apply(theme)
  ansi.set_code_map(theme.ansi or {})
  if type(psi.set_tui_theme) == "function" then
    psi.set_tui_theme(psi.json_encode(tui_payload(theme)))
  end
end

function M.register(name, theme)
  if type(name) ~= "string" or name == "" then
    return false, "theme name must be a non-empty string"
  end
  if type(theme) ~= "table" then
    return false, "theme spec must be a table"
  end
  local normalized = normalize(theme)
  normalized.name = name
  registry[name] = normalized
  return true
end

function M.use(theme_or_name)
  local name = theme_or_name
  local theme = theme_or_name
  if type(theme_or_name) == "string" then
    theme = registry[theme_or_name]
    if not theme then
      return false, "unknown theme: " .. theme_or_name
    end
  elseif type(theme_or_name) ~= "table" then
    return false, "theme must be a name or table"
  else
    theme = normalize(theme_or_name)
    name = theme.name or "<custom>"
  end
  current_name = tostring(name)
  current_theme = normalize(theme)
  current_theme.name = current_name
  apply(current_theme)
  return true
end

function M.current()
  return current_theme and deep_copy(current_theme) or nil
end

function M.current_name()
  return current_name
end

function M.names()
  local names = {}
  for name, _ in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.apply_configured()
  local name = configured_name()
  if name then
    local ok = M.use(name)
    if ok then
      return true
    end
  end
  if current_theme == nil then
    return M.use(DEFAULT_THEME_NAME)
  end
  return true
end

function M.bootstrap()
  M.register(DEFAULT_THEME_NAME, DEFAULT_THEME)
  return M.apply_configured()
end

return M
