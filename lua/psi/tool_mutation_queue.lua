-- psi.tool_mutation_queue: serialize mutation tools per path.
--
-- psi's tool scheduler can run tool calls concurrently. Reads and
-- searches can overlap freely, but two writes to the same path need a
-- small critical section so they cannot interleave through yielding
-- tool implementations later.

local M = {}

local locks = {}

local function key(path)
  if type(path) ~= "string" or path == "" then return nil end
  return path
end

function M.with_path(path, fn)
  local k = key(path)
  if not k then
    return fn()
  end
  while locks[k] do
    if coroutine.running() and psi and psi.sched and psi.sched.sleep_ms then
      psi.sched.sleep_ms(10)
    else
      break
    end
  end
  locks[k] = true
  local ok, a, b, c = pcall(fn)
  locks[k] = nil
  if not ok then error(a, 0) end
  return a, b, c
end

return M
