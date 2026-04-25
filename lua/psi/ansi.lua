-- psi.ansi: ANSI color helpers.
--
-- `M.enabled` gates every wrapper. Set false to emit plain text —
-- useful on terminals that don't interpret CSI sequences (9front rio,
-- Plan 9 in general, some dumb pipes). Also respects the de-facto
-- NO_COLOR env var.
--
-- Callers don't branch on M.enabled themselves; they just call M.cyan
-- / M.bold / etc. and get plain text back when ANSI is off.

local M = {}

local ESC = string.char(27)

M.enabled = true

function M.color(code, text)
  if not M.enabled then return text end
  return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end
function M.bold(text)   return M.color("1",  text) end
function M.dim(text)    return M.color("2",  text) end
function M.cyan(text)   return M.color("36", text) end
function M.green(text)  return M.color("32", text) end
function M.red(text)    return M.color("31", text) end
function M.yellow(text) return M.color("33", text) end

-- Autodetect environments that can't render ANSI. Called from
-- boot.lua after psi.* primitives are available.
function M.autodetect()
  if os.getenv("NO_COLOR") ~= nil and os.getenv("NO_COLOR") ~= "" then
    M.enabled = false
    return
  end
  local force = os.getenv("PSI_ANSI")
  if force == "0" or force == "off" or force == "false" then
    M.enabled = false
    return
  end
  if force == "1" or force == "on" or force == "true" then
    M.enabled = true
    return
  end
  -- 9front / Plan 9: rio terminals don't interpret CSI. The
  -- $sysname env var only exists when profile has been sourced
  -- (rcpu sessions skip that), so check for /dev/sysname instead —
  -- it's always present on Plan 9 and absent on Linux/Haiku.
  local sysname = io.open("/dev/sysname", "r")
  if sysname ~= nil then
    sysname:close()
    M.enabled = false
    return
  end
end

return M
