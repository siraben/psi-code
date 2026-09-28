-- psi.theme: ANSI theme registry. The single active theme drives
-- psi.ansi.* color output; extensions can register more.

local ansi = require("psi.ansi")
local settings = require("psi.settings_manager")

local M = {}

local registry = {}
local current_name = nil
local current_theme = nil

local DEFAULT_THEME_NAME = "pi-dark"
local LIGHT_THEME_NAME = "pi-light"
local TUI_SLOTS = {
  "header",
  "accent",
  "text",
  "warning",
  "success",
  "error",
  "chrome",
  "thinking_off",
  "thinking_minimal",
  "thinking_low",
  "thinking_medium",
  "thinking_high",
  "thinking_xhigh",
  "thinking_max",
}

local DEFAULT_THEME = {
  -- Current pi-mono dark theme color aliases, translated from OKHSL to
  -- truecolor SGR. See packages/coding-agent/.../theme/dark.json.
  ansi = {
    ["2"] = "38;2;126;136;142", -- dim
    ["31"] = "38;2;234;127;129", -- error/red
    ["32"] = "38;2;104;183;141", -- success/green
    ["33"] = "38;2;205;154;34", -- warning/yellow
    ["34"] = "38;2;95;168;204", -- border/blue
    ["36"] = "38;2;167;152;215", -- accent/violet
    ["37"] = "38;2;222;224;225", -- text
    ["90"] = "38;2;126;136;142",
    ["96"] = "38;2;167;152;215",
    ["1;36"] = "1;38;2;167;152;215",
    ["38;5;242"] = "38;2;157;165;169", -- muted/toolOutput
    ["38;5;245"] = "38;2;157;165;169",
    ["38;5;81"] = "38;2;167;152;215",
    ["38;5;108"] = "38;2;104;183;141",
    ["38;5;174"] = "38;2;234;127;129",
    ["38;5;221"] = "38;2;205;154;34",
    ["48;5;236"] = "48;2;52;56;58",
    ["48;5;22"] = "48;2;37;65;49",
    ["48;5;52"] = "48;2;91;40;42",
    ["48;5;237"] = "48;2;33;59;73",
    ["48;5;238"] = "48;2;33;59;73",
    ["md-link"] = "38;2;105;173;208",
    ["thinking-text"] = "38;2;150;160;164",
    ["bash-mode"] = "38;2;94;178;134",
    ["thinking-off"] = "38;2;108;118;123",
    ["thinking-minimal"] = "38;2;104;128;141",
    ["thinking-low"] = "38;2;84;137;164",
    ["thinking-medium"] = "38;2;97;133;204",
    ["thinking-high"] = "38;2;151;118;229",
    ["thinking-xhigh"] = "38;2;222;84;193",
    ["thinking-max"] = "38;2;254;84;98",
  },
  tui = {
    header = { fg = 74, bg = 234 },
    accent = { fg = 140, bg = 234 },
    text = { fg = 254, bg = 234 },
    warning = { fg = 178, bg = 234 },
    success = { fg = 108, bg = 234 },
    error = { fg = 174, bg = 234 },
    chrome = { fg = 247, bg = 234 },
    thinking_off = { fg = 243, bg = 234 },
    thinking_minimal = { fg = 66, bg = 234 },
    thinking_low = { fg = 67, bg = 234 },
    thinking_medium = { fg = 68, bg = 234 },
    thinking_high = { fg = 141, bg = 234 },
    thinking_xhigh = { fg = 170, bg = 234 },
    thinking_max = { fg = 203, bg = 234 },
  },
}

-- pi-mono light theme, translated to SGR. Mirrors
-- /root/pi-mono/packages/coding-agent/src/modes/interactive/theme/light.json
-- The tool background tints are deliberately pale so that the dark
-- toolTitle/text stays legible; the dark theme uses the inverse.
local LIGHT_THEME = {
  ansi = {
    ["2"] = "38;2;135;144;149", -- dim
    ["31"] = "38;2;200;37;61", -- error/red
    ["32"] = "38;2;51;126;88", -- success/green
    ["33"] = "38;2;143;104;2", -- warning/yellow
    ["34"] = "38;2;61;142;179", -- border/blue
    ["36"] = "38;2;116;89;180", -- accent/violet
    ["37"] = "38;2;59;63;65", -- text
    ["90"] = "38;2;135;144;149",
    ["96"] = "38;2;116;89;180",
    ["1;36"] = "1;38;2;116;89;180",
    ["38;5;242"] = "38;2;103;113;118", -- muted/toolOutput
    ["38;5;245"] = "38;2;103;113;118",
    ["38;5;81"] = "38;2;116;89;180",
    ["38;5;108"] = "38;2;51;126;88",
    ["38;5;174"] = "38;2;200;37;61",
    ["38;5;221"] = "38;2;143;104;2",
    ["48;5;236"] = "48;2;228;229;230",
    ["48;5;22"] = "48;2;222;233;225",
    ["48;5;52"] = "48;2;238;226;225",
    ["48;5;237"] = "48;2;223;231;236",
    ["48;5;238"] = "48;2;223;231;236",
    ["md-link"] = "38;2;47;120;153",
    ["thinking-text"] = "38;2;124;134;140",
    ["bash-mode"] = "38;2;64;151;108",
    ["thinking-off"] = "38;2;194;200;202",
    ["thinking-minimal"] = "38;2;181;196;203",
    ["thinking-low"] = "38;2;159;194;213",
    ["thinking-medium"] = "38;2;162;183;224",
    ["thinking-high"] = "38;2;181;165;232",
    ["thinking-xhigh"] = "38;2;229;133;205",
    ["thinking-max"] = "38;2;254;116;121",
  },
  tui = {
    header = { fg = 31, bg = 255 },
    accent = { fg = 97, bg = 255 },
    text = { fg = 238, bg = 255 },
    warning = { fg = 136, bg = 255 },
    success = { fg = 29, bg = 255 },
    error = { fg = 161, bg = 255 },
    chrome = { fg = 243, bg = 255 },
    thinking_off = { fg = 251, bg = 255 },
    thinking_minimal = { fg = 250, bg = 255 },
    thinking_low = { fg = 153, bg = 255 },
    thinking_medium = { fg = 147, bg = 255 },
    thinking_high = { fg = 183, bg = 255 },
    thinking_xhigh = { fg = 176, bg = 255 },
    thinking_max = { fg = 210, bg = 255 },
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
  ["thinking-off"] = "thinking_off",
  ["thinking-minimal"] = "thinking_minimal",
  ["thinking-low"] = "thinking_low",
  ["thinking-medium"] = "thinking_medium",
  ["thinking-high"] = "thinking_high",
  ["thinking-xhigh"] = "thinking_xhigh",
  ["thinking-max"] = "thinking_max",
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

-- Detect whether the terminal has a light or dark background so the
-- default theme can flip, mirroring pi's COLORFGBG-based detection
-- (packages/coding-agent/.../theme.ts detectTerminalBackgroundFromEnv).
-- Returns "light", "dark", or nil when there is no reliable hint.
local function detect_terminal_theme()
  local force = os.getenv("PSI_THEME_BACKGROUND")
  if force == "light" or force == "dark" then
    return force
  end
  local colorfgbg = os.getenv("COLORFGBG")
  if type(colorfgbg) == "string" and colorfgbg ~= "" then
    local bg = nil
    for part in colorfgbg:gmatch("[^;]+") do
      local n = tonumber((part:gsub("%s", "")))
      if n and n >= 0 and n <= 255 then
        bg = n
      end
    end
    if bg ~= nil then
      -- ANSI base indices 0-6 and 8 are dark; 7 and 15 (and other
      -- high-luminance indices) are light backgrounds.
      if bg == 7 or bg == 15 or bg >= 231 then
        return "light"
      end
      return "dark"
    end
  end
  return nil
end

local function default_theme_name()
  return detect_terminal_theme() == "light" and LIGHT_THEME_NAME or DEFAULT_THEME_NAME
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
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.thinking_border(level, text)
  level = tostring(level or "off"):lower()
  if
    level ~= "off"
    and level ~= "minimal"
    and level ~= "low"
    and level ~= "medium"
    and level ~= "high"
    and level ~= "xhigh"
    and level ~= "max"
  then
    level = "off"
  end
  return ansi.color("thinking-" .. level, tostring(text or ""))
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
  return M.use(default_theme_name())
end

function M.bootstrap()
  M.register(DEFAULT_THEME_NAME, DEFAULT_THEME)
  M.register(LIGHT_THEME_NAME, LIGHT_THEME)
  return M.apply_configured()
end

return M
