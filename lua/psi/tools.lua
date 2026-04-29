-- psi.tools: built-in tool registration and public registry surface.

local records = require("psi.records")
local registry = require("psi.tool_registry")

local M = {}

local BUILTINS = {
  "psi.tools.read",
  "psi.tools.bash",
  "psi.tools.edit",
  "psi.tools.write",
  "psi.tools.grep",
  "psi.tools.find",
  "psi.tools.ls",
  "psi.tools.lua",
}

for _, mod in ipairs(BUILTINS) do
  require(mod)()
end

local ok_mcp, mcp = pcall(require, "psi.mcp")
if ok_mcp and type(mcp.register_configured_servers) == "function" then
  mcp.register_configured_servers(registry, records)
elseif not ok_mcp then
  io.stderr:write("psi: MCP support failed to load: " .. tostring(mcp) .. "\n")
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
