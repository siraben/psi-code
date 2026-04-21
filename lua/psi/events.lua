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

local function list_for(event)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
  end
  return list
end

function M.on(event, fn)
  if type(event) ~= "string" or type(fn) ~= "function" then return end
  local list = list_for(event)
  list[#list + 1] = fn
end

function M.off(event, fn)
  local list = handlers[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
end

function M.emit(event, payload)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, payload)
    if not ok then
      io.stderr:write("psi.events: handler for '" .. tostring(event)
        .. "' failed: " .. tostring(err) .. "\n")
    end
  end
end

-- Introspection: returns a shallow copy of the handler list for `event`.
function M.handlers(event)
  local list = handlers[event] or {}
  local out = {}
  for i, fn in ipairs(list) do out[i] = fn end
  return out
end

return M
