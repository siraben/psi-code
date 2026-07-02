-- psi.tool_mutation_queue: serialize mutation tools per path.
--
-- psi's tool scheduler can run tool calls concurrently. Reads and
-- searches can overlap freely, but two writes to the same path need a
-- small critical section so they cannot interleave through yielding
-- tool implementations later.

local M = {}
local path_util = require("psi.path_utils")

local locks = {}

local function basename(path)
  return tostring(path):match("[^/\\]+$") or tostring(path)
end

local function key(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = path_util.resolve(path) or path
  local real = path_util.realpath(resolved)
  if real and real ~= "" then
    return real
  end
  local parent = path_util.parent(resolved)
  local real_parent = parent and path_util.realpath(parent) or nil
  if real_parent and real_parent ~= "" then
    return path_util.join(real_parent, basename(resolved)) or resolved
  end
  return resolved
end

-- Release the lock for `k`: hand ownership to the oldest waiter (FIFO)
-- or free the slot when nobody is queued.
local function release(k)
  local lock = locks[k]
  local waiter = lock and table.remove(lock.waiters, 1) or nil
  if waiter then
    waiter.ready = true
  else
    locks[k] = nil
  end
end

function M.with_path(path, fn)
  local k = key(path)
  if not k then
    return fn()
  end
  local lock = locks[k]
  if lock then
    if coroutine.running() and psi and psi.sched and psi.sched.sleep_ms then
      -- Sleep-poll our own flag: the scheduler has no wakeup primitive,
      -- and per-waiter flags keep hand-off FIFO and O(1) per release.
      local waiter = { ready = false }
      lock.waiters[#lock.waiters + 1] = waiter
      repeat
        psi.sched.sleep_ms(10)
      until waiter.ready
    end
    -- Non-coroutine callers cannot wait; they barge in.
  else
    locks[k] = { waiters = {} }
  end
  local ok, a, b, c = pcall(fn)
  release(k)
  if not ok then
    error(a, 0)
  end
  return a, b, c
end

return M
