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

-- MCP registration is deferred until something actually looks at the tool
-- registry (find/dispatch/select_specs/etc). Keeps `psi --eval` and
-- `psi --print` startup free of fork+exec+initialize round trips for
-- every configured MCP server, while keeping the surface unchanged for
-- agent / TUI / REPL paths that hit the registry as part of normal turn
-- setup.
local mcp_started = false

local function ensure_mcp_started()
  if mcp_started then
    return
  end
  mcp_started = true
  local ok_mcp, mcp = pcall(require, "psi.mcp")
  if ok_mcp and type(mcp.register_configured_servers) == "function" then
    mcp.register_configured_servers(registry, records)
  elseif not ok_mcp then
    io.stderr:write("psi: MCP support failed to load: " .. tostring(mcp) .. "\n")
  end
end

M.ensure_mcp_started = ensure_mcp_started

local function wrap(fn)
  return function(...)
    ensure_mcp_started()
    return fn(...)
  end
end

M.dispatch = wrap(registry.dispatch)
M.dispatch_alist = wrap(registry.dispatch_alist)
M.select_specs = wrap(registry.select_specs)
M.all = wrap(registry.all)
M.find = wrap(registry.find)
M.active = wrap(registry.active)
M.get_active = wrap(registry.get_active)
M.register = registry.register
M.add_before_hook = registry.add_before_hook
M.add_after_hook = registry.add_after_hook
M.clear_hooks = registry.clear_hooks
M.set_active = registry.set_active

-- Helper for before-hooks to cleanly cancel a tool call.
function M.cancel(reason, tool_name)
  return records.tool_failure(tool_name or "tool", reason or "cancelled by before-hook")
end

return M
