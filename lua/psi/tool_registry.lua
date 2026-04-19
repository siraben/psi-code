-- psi.tool_registry: declarative tool registration and dispatch.
--
-- Each tool is a records.Tool; the registry owns the list. Registered
-- tools are reachable via:
--   M.register(tool)
--   M.all() / M.find(name)
--   M.select_specs(user_text) -- alist list for the Anthropic adapter
--   M.dispatch(name, input)   -- returns ToolResult record
--   M.dispatch_alist(n, i)    -- returns alist (entry used by vm.c)

local records = require("psi.records")

local M = {}

local registry = {}

function M.register(tool)
  for i, existing in ipairs(registry) do
    if existing.name == tool.name then
      registry[i] = tool
      return
    end
  end
  registry[#registry + 1] = tool
end

function M.all() return registry end

function M.find(name)
  for _, t in ipairs(registry) do
    if t.name == name then return t end
  end
  return nil
end

-- Entry point for C-side schema serialization. user_text lets hosts
-- filter tools per-turn; current implementation returns all tools.
function M.select_specs(user_text)
  local out = {}
  for i, t in ipairs(registry) do out[i] = records.tool_to_alist(t) end
  return out
end

function M.dispatch(name, input)
  local tool = M.find(name)
  if not tool then
    return records.tool_failure(name, "unknown tool")
  end
  return tool.impl(input or {})
end

function M.dispatch_alist(name, input)
  return records.tool_result_to_alist(M.dispatch(name, input))
end

-- guardrail helpers used by tool impls
function M.require_string(input, key)
  local v = input[key]
  if type(v) == "string" and #v > 0 then return v end
  return nil
end

function M.optional_string(input, key, default)
  local v = input[key]
  if type(v) == "string" then return v end
  return default
end

function M.optional_number(input, key, default)
  local v = input[key]
  if type(v) == "number" then return v end
  return default
end

function M.optional_boolean(input, key, default)
  local v = input[key]
  if v == true then return true end
  if v == false then return default end
  return default
end

return M
