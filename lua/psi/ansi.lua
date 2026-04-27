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

local ESC = string.char(27)
local code_map = {}

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
    or code:match("38;5;%d+") ~= nil
    or code:match("48;5;%d+") ~= nil
    or code:match("^%d+;3[0-7]$") ~= nil
    or code:match("^%d+;9[0-7]$") ~= nil
    or code:match("^%d+;4[0-7]$") ~= nil
    or code:match("^%d+;10[0-7]$") ~= nil
end

local function resolve_code(code)
  local parts = {}
  code = tostring(code or "")
  for part in code:gmatch("[^;]+") do
    parts[#parts + 1] = code_map[part] or part
  end
  return #parts > 0 and table.concat(parts, ";") or code
end

function M.set_code_map(next_map)
  code_map = {}
  for key, value in pairs(next_map or {}) do
    if value ~= nil then
      code_map[tostring(key)] = tostring(value)
    end
  end
end

function M.color(code, text)
  if not M.enabled then
    return text
  end
  local resolved = resolve_code(code)
  if not M.color_enabled and is_color_code(resolved) then
    return text
  end
  return ESC .. "[" .. resolved .. "m" .. text .. ESC .. "[0m"
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
  if os.getenv("NO_COLOR") ~= nil and os.getenv("NO_COLOR") ~= "" then
    M.color_enabled = false
    return
  end
  local force = os.getenv("PSI_ANSI")
  if force == "0" or force == "off" or force == "false" then
    M.enabled = false
    return
  end
  if compiled_ansi and (force == "1" or force == "on" or force == "true") then
    M.enabled = true
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
