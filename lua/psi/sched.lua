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
  if req.h == nil then
    return nil, true
  end
  local chunk, done = psi.http_stream_poll(req.h, req.ms or 0)
  return chunk, done
end

M.resolvers["proc"] = function(req)
  if req.h == nil then
    return nil, true, 0
  end
  -- Wired in Stage 4; shim returns done for now.
  if psi.process_poll == nil then
    return nil, true, 0
  end
  local chunk, done, status = psi.process_poll(req.h, req.ms or 0)
  return chunk, done, status
end

M.resolvers["sleep"] = function(req)
  if psi.sleep_ms ~= nil then
    psi.sleep_ms(req.ms or 0)
  end
  return nil
end

M.resolvers["tick"] = function(_req)
  -- Empty tick: just give the tick_hook a chance to run.
  return nil
end

-- Run fn(...) as a coroutine; return all of fn's return values.
-- Propagates errors verbatim.
function M.run(fn, ...)
  local co = coroutine.create(fn)
  local args = table.pack(...)
  while true do
    local results = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
    local ok = results[1]
    if not ok then
      error(results[2], 0)
    end
    if coroutine.status(co) == "dead" then
      return table.unpack(results, 2, results.n)
    end
    -- results[2] is the yielded request (a table).
    local req = results[2]
    if type(req) ~= "table" or type(req.kind) ~= "string" then
      req = { kind = "tick" }
    end
    -- Host tick first (C side: TUI input + redraw). Safe to call
    -- even when no host has installed a hook (no-op then).
    if psi.host_tick ~= nil then
      psi.host_tick()
    end
    local ok_tick, tick_err = pcall(tick_hook, req)
    if not ok_tick then
      io.stderr:write("psi.sched tick hook error: " .. tostring(tick_err) .. "\n")
    end
    local resolver = M.resolvers[req.kind]
    if resolver == nil then
      args = table.pack(nil, "unknown request kind: " .. tostring(req.kind))
    else
      args = table.pack(resolver(req))
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

-- Run N functions concurrently as sub-coroutines. Each fn must
-- yield through the sched.* primitives (http_poll, proc_poll,
-- sleep_ms, yield_tick). The driver resumes each sub-coroutine
-- round-robin; when one yields a wait request, we resolve it
-- with a short timeout so the others stay responsive.
--
-- Returns an array of {ok, values} records in input order, where
-- values is a table.pack of the fn's return values on success, or
-- the error message on failure. Callers decide how to shape that
-- into their domain result.
--
-- Works correctly when called from within a sched.run coroutine:
-- the sub-coroutines yield to this function rather than to the
-- outer driver, so the outer coroutine just appears to be taking
-- a long time to complete.
--
-- Scheduler latency: with K concurrent tasks, a full round-robin
-- pass polls each task's yielded request with `short_wait(K)` ms.
-- Max latency to notice a ready chunk is K × short_wait. We cap at
-- 20 ms for K=1 (matches the previous constant) and shrink as K
-- grows so the floor doesn't scale linearly with concurrency.
local function short_wait(k)
  if k <= 1 then
    return 20
  end
  local per = 20 // k
  if per < 5 then
    per = 5
  end
  return per
end

function M.run_all(fns)
  local tasks = {}
  for i, fn in ipairs(fns) do
    tasks[i] = {
      co = coroutine.create(fn),
      done = false,
      next_args = {},
      next_n = 0,
      ok = false,
      values = nil,
      error_msg = nil,
    }
  end

  local remaining = #tasks
  while remaining > 0 do
    for _, t in ipairs(tasks) do
      if not t.done then
        local res = table.pack(coroutine.resume(t.co, table.unpack(t.next_args, 1, t.next_n)))
        if res[1] == false then
          t.done = true
          t.ok = false
          t.error_msg = res[2]
          remaining = remaining - 1
        elseif coroutine.status(t.co) == "dead" then
          local vals = { n = res.n - 1 }
          for j = 2, res.n do
            vals[j - 1] = res[j]
          end
          t.done = true
          t.ok = true
          t.values = vals
          remaining = remaining - 1
        else
          -- Yielded: res[2] is the request. Resolve it with a
          -- short timeout so the round-robin stays fair even if
          -- one task is chatty.
          local req = res[2]
          if type(req) ~= "table" or type(req.kind) ~= "string" then
            req = { kind = "tick" }
          end
          local wait_ms = short_wait(remaining)
          local short_req = req
          if req.kind == "http" or req.kind == "proc" then
            short_req = { kind = req.kind, h = req.h, ms = wait_ms }
          elseif req.kind == "sleep" then
            local ms = tonumber(req.ms) or 0
            if ms > wait_ms then
              short_req = { kind = "sleep", ms = wait_ms }
            end
          end
          local resolver = M.resolvers[req.kind]
          if resolver ~= nil then
            t.next_args = table.pack(resolver(short_req))
            t.next_n = t.next_args.n
          else
            t.next_args = table.pack(nil, "unknown request kind: " .. tostring(req.kind))
            t.next_n = t.next_args.n
          end
        end
      end
    end
    if remaining == 0 then
      break
    end
    -- Let the host loop keep pumping (TUI redraw, input, etc.).
    if psi.host_tick ~= nil then
      psi.host_tick()
    end
  end

  local out = {}
  for i, t in ipairs(tasks) do
    if t.ok then
      out[i] = { ok = true, values = t.values }
    else
      out[i] = { ok = false, error = t.error_msg }
    end
  end
  return out
end

return M
