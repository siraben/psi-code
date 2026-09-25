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

local notice = require("psi.notice")
local M = {}

-- handlers[event] = { { fn = fn1 }, { fn = fn2 }, ... }
local handlers = {}
-- snapshots[event] = immutable copy of handlers[event] used by emit.
-- Invalidated (never mutated) by on()/off() so an emit that is
-- mid-dispatch keeps iterating the array it captured.
local snapshots = {}
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
  local registration = { fn = fn }
  list[#list + 1] = registration
  snapshots[event] = nil
  return function()
    local current = handlers[event]
    if not current then
      return
    end
    for i = #current, 1, -1 do
      if current[i] == registration then
        table.remove(current, i)
        snapshots[event] = nil
        break
      end
    end
  end
end

function M.off(event, fn)
  local list = handlers[event]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if list[i].fn == fn then
      table.remove(list, i)
    end
  end
  snapshots[event] = nil
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
  local snapshot = snapshots[event]
  if snapshot == nil then
    snapshot = {}
    for i = 1, #list do
      snapshot[i] = list[i]
    end
    snapshots[event] = snapshot
  end
  local n = #snapshot
  for i = 1, n do
    local ok, err = pcall(snapshot[i].fn, payload)
    if not ok then
      notice.error(
        "psi.events: handler for '" .. tostring(event) .. "' failed: " .. tostring(err),
        { source = "event-bus" }
      )
    end
  end
end

-- Introspection: returns a shallow copy of the handler list for `event`.
function M.handlers(event)
  local list = handlers[event] or {}
  local out = {}
  for i, registration in ipairs(list) do
    out[i] = registration.fn
  end
  return out
end

function M.clear()
  handlers = {}
  snapshots = {}
end

return M
