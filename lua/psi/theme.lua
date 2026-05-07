-- psi.theme: ANSI theme registry. The single active theme drives
-- psi.ansi.* color output; extensions can register more.

local ansi = require("psi.ansi")
local settings = require("psi.settings_manager")

local M = {}

local registry = {}
local current_name = nil
local current_theme = nil

local DEFAULT_THEME_NAME = "pi-dark"
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
  -- pi-mono dark theme color aliases, translated to SGR. See
  -- /root/pi-mono/packages/coding-agent/src/modes/interactive/theme/dark.json
  ansi = {
    ["2"] = "38;2;102;102;102", -- dim #666666
    ["31"] = "38;2;204;102;102", -- error/red #cc6666
    ["32"] = "38;2;181;189;104", -- success/green #b5bd68
    ["33"] = "38;2;255;255;0", -- warning/yellow #ffff00
    ["34"] = "38;2;95;135;255", -- border/blue #5f87ff
    ["36"] = "38;2;138;190;183", -- accent #8abeb7
    ["37"] = "37", -- pi text is default fg; keep white-ish ANSI fallback
    ["90"] = "38;2;102;102;102", -- dimGray #666666
    ["96"] = "38;2;0;215;255", -- cyan #00d7ff
    ["1;36"] = "1;38;2;138;190;183",
    ["38;5;242"] = "38;2;128;128;128", -- gray/toolOutput #808080
    ["38;5;245"] = "38;2;128;128;128",
    ["38;5;81"] = "38;2;0;215;255",
    ["38;5;108"] = "38;2;181;189;104",
    ["38;5;174"] = "38;2;204;102;102",
    ["38;5;221"] = "38;2;255;255;0",
    ["48;5;236"] = "48;2;40;40;50",
    ["48;5;22"] = "48;2;40;50;40",
    ["48;5;52"] = "48;2;60;40;40",
    ["48;5;237"] = "48;2;58;58;74",
    ["48;5;238"] = "48;2;52;53;65",
  },
  tui = {
    header = { fg = 81, bg = 234 },
    accent = { fg = 115, bg = 234 },
    text = { fg = 253, bg = 234 },
    warning = { fg = 226, bg = 234 },
    success = { fg = 150, bg = 234 },
    error = { fg = 174, bg = 234 },
    chrome = { fg = 244, bg = 234 },
  },
}

local ANSI_SLOT_CODES = {
  ["31"] = "error",
  ["32"] = "success",
  ["33"] = "warning",
  ["34"] = "header",
  ["36"] = "accent",
  ["1;36"] = "accent",
  ["37"] = "text",
  ["38;5;242"] = "chrome",
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
  local user_ansi = type(theme) == "table" and type(theme.ansi) == "table" and theme.ansi or {}
  local user_tui = type(theme) == "table" and type(theme.tui) == "table" and theme.tui or {}
  local merged = merge(deep_copy(DEFAULT_THEME), theme or {})
  for _, slot in ipairs(TUI_SLOTS) do
    local spec = merged.tui[slot] or {}
    merged.tui[slot] = {
      fg = tonumber(spec.fg) or -1,
      bg = tonumber(spec.bg) or -1,
    }
  end
  for code, slot in pairs(ANSI_SLOT_CODES) do
    if user_ansi[code] == nil and user_tui[slot] ~= nil then
      local fg = merged.tui[slot] and merged.tui[slot].fg or -1
      merged.ansi[code] = fg >= 0 and ("38;5;" .. tostring(fg)) or code
    elseif merged.ansi[code] == nil then
      local fg = merged.tui[slot] and merged.tui[slot].fg or -1
      if fg >= 0 then
        merged.ansi[code] = "38;5;" .. tostring(fg)
      else
        merged.ansi[code] = code
      end
    end
  end
  return merged
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
  local theme
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

function M.apply_configured(opts)
  opts = type(opts) == "table" and opts or {}
  local name = configured_name()
  if name then
    local ok = M.use(name)
    if ok then
      return true
    end
  end
  if opts.preserve_current and current_theme ~= nil then
    apply(current_theme)
    return true
  end
  return M.use(DEFAULT_THEME_NAME)
end

function M.bootstrap()
  M.register(DEFAULT_THEME_NAME, DEFAULT_THEME)
  return M.apply_configured()
end

return M
