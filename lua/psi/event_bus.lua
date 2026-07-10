-- psi.events: neutral pub/sub bus for extensions and internal observers.
--
-- Separate from psi.render.register_hook, which has a string-concat
-- contract (handlers return rendered strings that get joined into the
-- terminal output). This module's handlers are fire-and-forget; return
-- values are ignored, so adding subscribers never disturbs rendering.
--
-- Handlers are invoked synchronously in registration order. Errors are
-- swallowed per handler with a stderr log line so one bad subscriber
-- cannot take down an agent turn.

local M = {}

-- handlers[event] = { fn1, fn2, ... }
local handlers = {}
local aliases = {
  ["session-start"] = "session_start",
  ["session-shutdown"] = "session_shutdown",
  ["turn-start"] = "turn_start",
  ["turn-end"] = "turn_end",
  ["tool-call"] = "tool_execution_start",
  ["tool-result"] = "tool_execution_end",
  ["assistant-text-delta"] = "message_update",
  ["before-provider-request"] = "before_provider_request",
  ["after-provider-response"] = "after_provider_response",
  ["compaction-start"] = "session_before_compact",
  ["compaction-end"] = "session_compact",
}

local function list_for(event)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
  end
  return list
end

function M.on(event, fn)
  if type(event) ~= "string" or type(fn) ~= "function" then
    return
  end
  local list = list_for(event)
  list[#list + 1] = fn
end

function M.off(event, fn)
  local list = handlers[event]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if list[i] == fn then
      table.remove(list, i)
    end
  end
end

function M.emit(event, payload)
  local alias = aliases[event]
  if alias and alias ~= event then
    M.emit(alias, payload)
  end
  local list = handlers[event]
  if not list then
    return
  end
  -- Snapshot the handler list before iterating. A handler that calls
  -- psi.events.on/off for the SAME event during emission would
  -- otherwise mutate the array ipairs is walking — registering a new
  -- handler could cause it to fire in the same cycle (unexpected),
  -- and unregistering via table.remove would shift subsequent
  -- handlers left and skip one.
  local snapshot = {}
  local n = #list
  for i = 1, n do
    snapshot[i] = list[i]
  end
  for i = 1, n do
    local ok, err = pcall(snapshot[i], payload)
    if not ok then
      io.stderr:write(
        "psi.events: handler for '" .. tostring(event) .. "' failed: " .. tostring(err) .. "\n"
      )
    end
  end
end

-- Introspection: returns a shallow copy of the handler list for `event`.
function M.handlers(event)
  local list = handlers[event] or {}
  local out = {}
  for i, fn in ipairs(list) do
    out[i] = fn
  end
  return out
end

function M.clear()
  handlers = {}
end

return M
