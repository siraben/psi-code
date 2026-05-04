-- psi.tools: built-in tool registration and public registry surface.

local records = require("psi.records")
local registry = require("psi.tool_registry")

local M = {}

-- Tool registration is gated by capabilities so constrained builds
-- (e.g. ESP32 without process execution) don't expose tools that
-- would always fail. Desktop reports every capability true and
-- registers everything; an ESP32 build with process=false drops
-- bash/grep/find automatically.
local caps = psi.runtime_info().capabilities or {}
local has_storage = caps.filesystem or caps.ramfs
local can_read = has_storage or caps.embedded_resources

local BUILTINS = {
  { mod = "psi.tools.read", needs = can_read },
  { mod = "psi.tools.bash", needs = caps.process == true },
  { mod = "psi.tools.edit", needs = has_storage == true },
  { mod = "psi.tools.write", needs = has_storage == true },
  { mod = "psi.tools.grep", needs = caps.process == true },
  { mod = "psi.tools.find", needs = caps.process == true },
  { mod = "psi.tools.ls", needs = can_read == true },
  { mod = "psi.tools.lua", needs = true },
}

for _, entry in ipairs(BUILTINS) do
  if entry.needs then
    require(entry.mod)()
  end
end

M.dispatch = registry.dispatch
M.dispatch_alist = registry.dispatch_alist
M.select_specs = registry.select_specs
M.all = registry.all
M.find = registry.find
M.register = registry.register
M.add_before_hook = registry.add_before_hook
M.add_after_hook = registry.add_after_hook
M.clear_hooks = registry.clear_hooks
M.set_active = registry.set_active
M.get_active = registry.get_active
M.active = registry.active

-- Helper for before-hooks to cleanly cancel a tool call.
function M.cancel(reason, tool_name)
  return records.tool_failure(tool_name or "tool", reason or "cancelled by before-hook")
end

return M
