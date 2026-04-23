-- psi.sched: cooperative coroutine driver.
--
-- A turn function `fn` is run inside a Lua coroutine. At every
-- yield point it pushes a small request table upward; the driver
-- (running on the single host thread, the only owner of the
-- lua_State) resolves the request and resumes the coroutine with
-- the result.
--
-- Why not just blocking FFI? Because during a streaming agent turn
-- the TUI main loop needs to keep pumping: redraw, getch,
-- process-poll. We express that by having every blocking
-- primitive yield back to the driver, which takes the chance to
-- run one tick of the TUI event loop before resolving.
--
-- In non-TUI modes (print, agent, REPL, eval) there is no event
-- loop to pump; the driver simply resolves each request directly
-- and resumes. Same Lua code, two drivers.

local M = {}

-- The TUI (or any other host) can install a per-resume hook that
-- advances its own state one step. The default is a no-op (print/
-- agent/REPL don't need to interleave with anything else).
local tick_hook = function() end

function M.set_tick_hook(fn)
  tick_hook = fn or function() end
end

function M.clear_tick_hook()
  tick_hook = function() end
end

-- Default resolvers for the built-in request kinds. The table is
-- exposed so the TUI driver (or a test harness) can override any
-- specific kind without replacing the whole loop.
M.resolvers = {}

M.resolvers["http"] = function(req)
  if req.h == nil then return nil, true end
  local chunk, done = psi.http_stream_poll(req.h, req.ms or 0)
  return chunk, done
end

M.resolvers["proc"] = function(req)
  if req.h == nil then return nil, true, 0 end
  -- Wired in Stage 4; shim returns done for now.
  if psi.process_poll == nil then return nil, true, 0 end
  local chunk, done, status = psi.process_poll(req.h, req.ms or 0)
  return chunk, done, status
end

M.resolvers["sleep"] = function(req)
  if psi.sleep_ms ~= nil then psi.sleep_ms(req.ms or 0) end
  return nil
end

M.resolvers["tick"] = function(_req)
  -- Empty tick: just give the tick_hook a chance to run.
  return nil
end

-- Run fn(...) as a coroutine; return whatever fn returns.
-- Propagates errors with a traceback.
function M.run(fn, ...)
  local co = coroutine.create(fn)
  local args = { ... }
  local nargs = select("#", ...)
  while true do
    local ok, req_or_result = coroutine.resume(co, table.unpack(args, 1, nargs))
    if not ok then
      error(req_or_result, 0)
    end
    if coroutine.status(co) == "dead" then
      return req_or_result
    end
    local req = req_or_result
    if type(req) ~= "table" or type(req.kind) ~= "string" then
      -- Unknown yield shape — treat as a pure "let the loop tick"
      req = { kind = "tick" }
    end
    -- Let the host advance its own loop (redraw, input, etc.).
    local ok_tick, tick_err = pcall(tick_hook, req)
    if not ok_tick then
      io.stderr:write("psi.sched tick hook error: " .. tostring(tick_err) .. "\n")
    end
    local resolver = M.resolvers[req.kind]
    if resolver == nil then
      args = { nil, "unknown request kind: " .. tostring(req.kind) }
      nargs = 2
    else
      local a, b, c = resolver(req)
      args = { a, b, c }
      nargs = 3
    end
  end
end

-- Yield helpers. Callers write these inside the coroutine body.

function M.yield_tick()
  return coroutine.yield({ kind = "tick" })
end

function M.sleep_ms(ms)
  return coroutine.yield({ kind = "sleep", ms = ms })
end

function M.http_poll(handle, timeout_ms)
  return coroutine.yield({ kind = "http", h = handle, ms = timeout_ms })
end

function M.proc_poll(handle, timeout_ms)
  return coroutine.yield({ kind = "proc", h = handle, ms = timeout_ms })
end

-- Helper: is the current execution inside a coroutine? Lets
-- callers decide whether to yield (cooperative) vs. busy-poll.
function M.in_coroutine()
  local _, main = coroutine.running()
  return main == false
end

return M
