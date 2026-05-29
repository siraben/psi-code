-- psi.tool_registry: declarative tool registration and dispatch.
--
-- Each tool is a records.Tool; the registry owns the list. Registered
-- tools are reachable via:
--   M.register(tool)
--   M.all() / M.find(name)
--   M.select_specs(user_text) -- alist list for the Anthropic adapter
--   M.dispatch(name, input)   -- returns ToolResult record
--   M.dispatch_alist(n, i)    -- returns alist (entry used by vm.c)
--
-- IMPORTANT: to invoke a tool and run the registered before/after
-- hook chain, call M.dispatch(name, input) (or the shim
-- psi.tool_call(name, input) on the global). The raw `tool.impl`
-- field on a Tool record is the *unhooked* implementation — calling
-- it directly (e.g. `find("read").impl(...)`) bypasses permission
-- gating, redaction, and any transformations extensions have
-- installed. Treat `impl` as an internal slot.

local records = require("psi.records")

local M = {}

local registry = {}
local before_hooks = {}
local after_hooks = {}

function M.register(tool)
  for i, existing in ipairs(registry) do
    if existing.name == tool.name then
      registry[i] = tool
      return
    end
  end
  registry[#registry + 1] = tool
end

function M.all()
  return registry
end

function M.find(name)
  for _, t in ipairs(registry) do
    if t.name == name then
      return t
    end
  end
  return nil
end

-- Per-session active-tools allowlist. When nil, all registered tools
-- are offered to the model (default). When set to a set of names via
-- M.set_active({"read","grep"}), select_specs returns only those
-- tools, narrowing what the LLM can call. Lets extensions / skills
-- scope an agent to a safe subset without unregistering tools
-- globally. Reset with M.set_active(nil).
local active_allowlist = nil

function M.set_active(names)
  if names == nil then
    active_allowlist = nil
    return
  end
  if type(names) ~= "table" then
    return
  end
  local set = {}
  for _, n in ipairs(names) do
    if type(n) == "string" and n ~= "" then
      set[n] = true
    end
  end
  active_allowlist = set
end

function M.get_active()
  if active_allowlist == nil then
    local out = {}
    for i, t in ipairs(registry) do
      out[i] = t.name
    end
    return out
  end
  local out = {}
  for _, t in ipairs(registry) do
    if active_allowlist[t.name] then
      out[#out + 1] = t.name
    end
  end
  return out
end

-- Same filter as get_active but returns the full Tool records
-- (name / description / prompt_snippet / guidelines / impl). Used by
-- psi.prompt.system_prompt so the "Available tools:" section in the
-- system prompt reflects what the model can actually call — without
-- this, set_active hides tools from dispatch but the prompt still
-- advertises them, and the model wastes tokens calling tools that
-- get rejected.
function M.active()
  if active_allowlist == nil then
    return registry
  end
  local out = {}
  for _, t in ipairs(registry) do
    if active_allowlist[t.name] then
      out[#out + 1] = t
    end
  end
  return out
end

-- Entry point for C-side schema serialization. user_text lets hosts
-- filter tools per-turn; honours M.set_active if a scope is active.
function M.select_specs(user_text)
  local out = {}
  for _, t in ipairs(registry) do
    if active_allowlist == nil or active_allowlist[t.name] then
      out[#out + 1] = records.tool_to_alist(t)
    end
  end
  return out
end

-- Hook registration:
--   before(name, input) may return nil (proceed), a ToolResult record
--     (replace the dispatch — tool impl is NOT called), or raise.
--     Common uses: permission gating, dry-run interception, logging.
--   after(name, input, result) may return a replacement ToolResult or
--     nil (keep result). Common uses: redaction, output transformation.
function M.add_before_hook(fn)
  before_hooks[#before_hooks + 1] = fn
end
function M.add_after_hook(fn)
  after_hooks[#after_hooks + 1] = fn
end
function M.clear_hooks()
  before_hooks = {}
  after_hooks = {}
end

-- `meta` is an optional opts table carrying context the host wants
-- to pass through to the tool impl. Today the only field we use is
-- meta.tool_call_id, which lets tools that stream progress
-- (bash/grep/find/ls via psi.tool_shell) tag their on_tool_progress
-- events with the right id — essential when multiple tools run
-- concurrently (psi.sched.run_all). Older impls that only accept
-- `input` stay compatible since the extra arg is optional.
function M.dispatch(name, input, meta)
  input = input or {}
  if active_allowlist ~= nil and not active_allowlist[name] then
    return records.tool_failure(name, "Tool " .. tostring(name) .. " not found")
  end
  for _, hook in ipairs(before_hooks) do
    local intercept = hook(name, input, meta)
    if intercept ~= nil then
      return intercept
    end
  end

  local tool = M.find(name)
  local result
  if not tool then
    result = records.tool_failure(name, "unknown tool")
  else
    result = tool.impl(input, meta)
  end

  for _, hook in ipairs(after_hooks) do
    local replaced = hook(name, input, result, meta)
    if replaced ~= nil then
      result = replaced
    end
  end
  return result
end

function M.dispatch_alist(name, input, meta)
  return records.tool_result_to_alist(M.dispatch(name, input, meta))
end

-- guardrail helpers used by tool impls
function M.require_string(input, key)
  local v = input[key]
  if type(v) == "string" and #v > 0 then
    return v
  end
  return nil
end

function M.optional_string(input, key, default)
  local v = input[key]
  if type(v) == "string" then
    return v
  end
  return default
end

function M.optional_number(input, key, default)
  local v = input[key]
  if type(v) == "number" then
    return v
  end
  return default
end

function M.optional_boolean(input, key, default)
  local v = input[key]
  if v == true then
    return true
  end
  if v == false then
    return false
  end
  return default
end

return M
