-- psi.tool_shell: POSIX shell quoting and command-result wrapping.

local records = require("psi.records")
local sched = require("psi.sched")

local M = {}

-- Wraps text in single quotes with '\'' escapes for embedded quotes.
function M.quote(text)
  if text == nil then
    return "''"
  end
  local parts = { "'" }
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "'" then
      parts[#parts + 1] = "'\\''"
    else
      parts[#parts + 1] = ch
    end
  end
  parts[#parts + 1] = "'"
  return table.concat(parts)
end

-- Run a shell command. Inside a coroutine we drive the async
-- process-handle via sched.proc_poll so the TUI event loop keeps
-- pumping between reads. Outside a coroutine (scripts, tests) we
-- fall back to the blocking psi.process_run.
--
-- tool_call_id, if passed, tags each chunk fed to
-- psi.tool_progress so the TUI observer can route the stream
-- into the right per-tool panel. Multiple tools running under
-- psi.sched.run_all each own their own id; without it, concurrent
-- tools would be indistinguishable on the wire.
function M.process_result(command, tool_call_id)
  if not sched.in_coroutine() then
    return records.process_result_from_alist(psi.process_run(command))
  end

  local handle, err = psi.process_begin(command)
  if handle == nil then
    -- Synthesize a failing result shaped the same way process_run would.
    return records.process_result_from_alist({
      output = tostring(err or "process_begin failed"),
      status = -1,
      truncated = false,
    })
  end

  local parts = {}
  while true do
    local chunk, done = sched.proc_poll(handle, 50)
    if chunk ~= nil and #chunk > 0 then
      parts[#parts + 1] = chunk
      -- Fire a live progress event for the TUI (no-op if no
      -- observer is registered, e.g. under --eval / --print).
      if psi.tool_progress ~= nil then
        psi.tool_progress(tool_call_id, chunk)
      end
    end
    if done then break end
  end

  local result = psi.process_finish(handle)
  -- Prefer the handle's reassembled buffer (covers the case where
  -- we drained after the 256 KiB ceiling); otherwise use what we
  -- captured via sched.proc_poll.
  if result.output == nil or result.output == "" then
    result.output = table.concat(parts)
  end
  return records.process_result_from_alist(result)
end

-- Run a shell command and wrap as a ToolResult.
-- `meta.tool_call_id`, if present, is threaded through so live
-- progress events carry the right id for multi-tool turns.
function M.run_tool(tool_name, command, path, keep_output_on_error, meta)
  local proc = M.process_result(command, meta and meta.tool_call_id or nil)
  local ok = proc:ok()
  local include_output = keep_output_on_error or ok or (proc.output and #proc.output > 0)
  local extras = {}
  if path then
    extras.path = path
  end
  extras.command = command
  extras.status = proc.status
  extras.truncated = proc.truncated
  if include_output then
    extras.output = proc.output or ""
  end
  return records.new_tool_result(ok, tool_name, nil, extras)
end

return M
