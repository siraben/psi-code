-- psi.platform: cheap, memoised host-OS predicates.
--
-- The agent runtime cares about Plan 9 in a couple of places (ANSI
-- gating, tool fallbacks for grep/find/bash) so the detection lives
-- here once. /dev/sysname is always present on Plan 9 and absent on
-- Linux/Haiku/macOS — distinct from $sysname env, which only exists
-- when /lib/profile has run (rcpu sessions skip that).

local M = {}

local _is_plan9 = nil
function M.is_plan9()
  if _is_plan9 == nil then
    local f = io.open("/dev/sysname", "r")
    _is_plan9 = f ~= nil
    if f then f:close() end
  end
  return _is_plan9
end

return M
