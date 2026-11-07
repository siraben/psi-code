-- psi.ansi: ANSI color helpers.
--
-- `M.enabled` gates every wrapper. `M.color_enabled` gates color SGR
-- codes while still allowing non-color styles such as bold or dim.
-- This is useful on terminals that don't interpret CSI sequences
-- (dumb pipes and the like). Also respects the de-facto NO_COLOR env var.
--
-- Callers don't branch on M.enabled themselves; they just call M.cyan
-- / M.bold / etc. and get plain text back when ANSI is off.

local M = {}
local platform = require("psi.platform")

local ESC = string.char(27)
local code_map = {}
local code_map_generation = 0
-- Semantic slots still emit valid SGR when no theme has been installed.
local semantic_fallbacks = {
  ["md-heading"] = "33",
  ["md-link"] = "34",
  ["md-link-url"] = "2",
  ["md-bullet"] = "36",
  ["thinking-text"] = "38;5;242",
  ["bash-mode"] = "32",
}
-- Codes form a small closed set, so memoize resolve results per code
-- string; the memo is invalidated whenever the code map changes.
local resolve_cache = {}

M.enabled = true
M.color_enabled = true

local function is_color_code(code)
  code = tostring(code or "")
  return code:match("^3[0-7]$") ~= nil
    or code:match("^9[0-7]$") ~= nil
    or code:match("^4[0-7]$") ~= nil
    or code:match("^10[0-7]$") ~= nil
    or code:match("^38;5;%d+$") ~= nil
    or code:match("^48;5;%d+$") ~= nil
    or code:match("^38;2;%d+;%d+;%d+$") ~= nil
    or code:match("^48;2;%d+;%d+;%d+$") ~= nil
    or code:match("38;5;%d+") ~= nil
    or code:match("48;5;%d+") ~= nil
    or code:match("38;2;%d+;%d+;%d+") ~= nil
    or code:match("48;2;%d+;%d+;%d+") ~= nil
    or code:match("^%d+;3[0-7]$") ~= nil
    or code:match("^%d+;9[0-7]$") ~= nil
    or code:match("^%d+;4[0-7]$") ~= nil
    or code:match("^%d+;10[0-7]$") ~= nil
end

local function resolve_code(code)
  local parts = {}
  code = tostring(code or "")
  if code_map[code] ~= nil then
    return code_map[code]
  end
  local cached = resolve_cache[code]
  if cached ~= nil then
    return cached
  end
  code = semantic_fallbacks[code] or code
  if code_map[code] ~= nil then
    return code_map[code]
  end
  local values = {}
  for part in code:gmatch("[^;]+") do
    values[#values + 1] = part
  end
  local i = 1
  while i <= #values do
    local part = values[i]
    local next_part = values[i + 1]
    if (part == "38" or part == "48") and next_part == "5" and values[i + 2] ~= nil then
      local extended = part .. ";" .. next_part .. ";" .. values[i + 2]
      parts[#parts + 1] = code_map[extended] or extended
      i = i + 3
    elseif
      (part == "38" or part == "48")
      and next_part == "2"
      and values[i + 2] ~= nil
      and values[i + 3] ~= nil
      and values[i + 4] ~= nil
    then
      local truecolor = part
        .. ";"
        .. next_part
        .. ";"
        .. values[i + 2]
        .. ";"
        .. values[i + 3]
        .. ";"
        .. values[i + 4]
      parts[#parts + 1] = code_map[truecolor] or truecolor
      i = i + 5
    else
      parts[#parts + 1] = code_map[part] or part
      i = i + 1
    end
  end
  local resolved = #parts > 0 and table.concat(parts, ";") or code
  resolve_cache[code] = resolved
  return resolved
end

local basic_palette = {
  { 0, 0, 0 },
  { 170, 0, 0 },
  { 0, 170, 0 },
  { 170, 85, 0 },
  { 0, 0, 170 },
  { 170, 0, 170 },
  { 0, 170, 170 },
  { 170, 170, 170 },
}
local terminal_code_cache = {}

local function basic_color(background, r, g, b)
  if background == "3" and math.max(r, g, b) - math.min(r, g, b) <= 10 then
    -- Gray foregrounds collapse onto the background in an eight-color
    -- palette. Use the theme's text polarity rather than invisible dim text.
    local tr, tg, tb = resolve_code("37"):match("38;2;(%d+);(%d+);(%d+)")
    if tr then
      return tonumber(tr) + tonumber(tg) + tonumber(tb) >= 384 and "37" or "30"
    end
  end
  local best, distance = 0, math.huge
  for index, rgb in ipairs(basic_palette) do
    local d = (r - rgb[1]) ^ 2 + (g - rgb[2]) ^ 2 + (b - rgb[3]) ^ 2
    if d < distance then
      best, distance = index - 1, d
    end
  end
  return tostring((background == "4" and 40 or 30) + best)
end

local function terminal_code(code)
  if platform.terminal_profile().colors ~= 8 then
    return code
  end
  if terminal_code_cache[code] then
    return terminal_code_cache[code]
  end
  local out = code:gsub("([34])8;2;(%d+);(%d+);(%d+)", function(bg, r, g, b)
    return basic_color(bg, tonumber(r), tonumber(g), tonumber(b))
  end)
  out = out:gsub("([34])8;5;(%d+)", function(bg, value)
    local n = math.min(255, tonumber(value))
    if n < 8 then
      return tostring((bg == "4" and 40 or 30) + n)
    end
    if n < 16 then
      return tostring((bg == "4" and 40 or 30) + n - 8)
    end
    if n >= 232 then
      local gray = 8 + (n - 232) * 10
      return basic_color(bg, gray, gray, gray)
    end
    n = n - 16
    local levels = { 0, 95, 135, 175, 215, 255 }
    return basic_color(
      bg,
      levels[math.floor(n / 36) + 1],
      levels[math.floor(n / 6) % 6 + 1],
      levels[n % 6 + 1]
    )
  end)
  terminal_code_cache[code] = out
  return out
end

function M.resolve(code)
  return terminal_code(resolve_code(code))
end

function M.generation()
  return code_map_generation
end

function M.set_code_map(next_map)
  code_map_generation = code_map_generation + 1
  code_map = {}
  resolve_cache = {}
  terminal_code_cache = {}
  for key, value in pairs(next_map or {}) do
    if value ~= nil then
      code_map[tostring(key)] = tostring(value)
    end
  end
end

function M.sgr(code)
  if not M.enabled then
    return ""
  end
  local resolved = M.resolve(code)
  if
    (not M.color_enabled or platform.terminal_profile().colors == 0) and is_color_code(resolved)
  then
    return ""
  end
  return ESC .. "[" .. resolved .. "m"
end

function M.color(code, text)
  local prefix = M.sgr(code)
  if prefix == "" then
    return text
  end
  return prefix .. text .. ESC .. "[0m"
end
function M.bold(text)
  return M.color("1", text)
end
function M.dim(text)
  return M.color("2", text)
end
function M.cyan(text)
  return M.color("36", text)
end
function M.green(text)
  return M.color("32", text)
end
function M.red(text)
  return M.color("31", text)
end
function M.yellow(text)
  return M.color("33", text)
end
function M.gray(text)
  return M.color("38;5;242", text)
end
function M.italic(text)
  return M.color("3", M.gray(text))
end
function M.inverse(text)
  return M.color("7", text)
end

-- Autodetect environments that can't render ANSI. Called from
-- boot.lua after psi.* primitives are available.
function M.autodetect()
  local info = type(psi) == "table" and psi.runtime_info and psi.runtime_info() or {}
  local compiled_ansi = info.ansi ~= false
  local compiled_color = info.color ~= false
  if info.ansi == false then
    M.enabled = false
  end
  if info.color == false then
    M.color_enabled = false
  end
  -- Plain output when stdout is not a terminal (pi print-mode parity); the force flags below still win.
  if type(psi) == "table" and type(psi.stdout_is_tty) == "function" and not psi.stdout_is_tty() then
    M.enabled = false
    M.color_enabled = false
  end
  local no_color = os.getenv("NO_COLOR") ~= nil and os.getenv("NO_COLOR") ~= ""
  if no_color then
    M.color_enabled = false
  end
  local force = os.getenv("PSI_ANSI")
  if force == "0" or force == "off" or force == "false" then
    M.enabled = false
    M.color_enabled = false
    return
  end
  if compiled_ansi and (force == "1" or force == "on" or force == "true") then
    M.enabled = true
  elseif compiled_ansi and not platform.windows_ansi_supported() then
    M.enabled = false
    M.color_enabled = false
    return
  end
  if no_color then
    return
  end
  force = os.getenv("PSI_COLOR")
  if force == "0" or force == "off" or force == "false" then
    M.color_enabled = false
    return
  end
  if compiled_color and (force == "1" or force == "on" or force == "true") then
    M.color_enabled = true
    return
  end
end

return M
