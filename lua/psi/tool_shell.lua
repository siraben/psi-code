-- psi.tool_shell: POSIX shell quoting and command-result wrapping.

local records = require("psi.records")
local sched = require("psi.sched")
local truncate = require("psi.truncate")

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

-- ---------------------------------------------------------------------------
-- Streaming runner. Drives process_begin / process_poll / process_finish
-- from inside a coroutine and accumulates chunks in Lua so we can do
-- tail-truncation that matches pi-mono. When total bytes exceed the
-- in-memory threshold we additionally spill the full output to a temp
-- file (mirroring pi's fs.createWriteStream path), so the model can
-- read the rest with the `read` tool.
--
-- Returns: { output=<string>, status=<int>, truncated=<bool>,
--            temp_file_path=<string|nil>, total_bytes=<int>,
--            total_lines=<int>, mode="tail"|"head" }.
--
-- `opts` may include:
--   max_bytes      : soft cap for in-memory output (default 50 KiB)
--   max_lines      : line cap (default 2000)
--   mode           : "tail" or "head" (default "tail" for bash-style commands)
--   spill_to_disk  : write the full output to a temp file once the soft
--                    cap is exceeded (default true)
--
-- Outside a coroutine (scripts, tests) we fall back to a blocking
-- psi.process_run / psi.process_run_argv. We then mimic the same
-- truncation logic on the returned text.
-- ---------------------------------------------------------------------------

local function blocking_poll(handle, ms)
  -- Outside a coroutine we can't yield. Just call the C primitive
  -- directly; it blocks for up to `ms` ms waiting for output.
  return psi.process_poll(handle, ms or 50)
end

local function stream(handle, tool_call_id, opts, poll_fn)
  opts = opts or {}
  local max_bytes = opts.max_bytes or truncate.DEFAULT_MAX_BYTES
  local rolling_max = max_bytes * 4 -- enough headroom for tail truncation
  local spill_to_disk = opts.spill_to_disk
  if spill_to_disk == nil then spill_to_disk = true end

  -- Rolling buffer for the in-memory tail. We keep at most `rolling_max`
  -- bytes here; older bytes are dropped, mirroring pi's bash rolling
  -- buffer. The full output (if it fits) is reconstructed by reading
  -- back the temp file.
  local buf = {}
  local buf_bytes = 0
  local total_bytes = 0
  local temp_path = nil
  local temp_open_failed = false

  local function trim_rolling()
    while buf_bytes > rolling_max and #buf > 1 do
      local removed = buf[1]
      table.remove(buf, 1)
      buf_bytes = buf_bytes - #removed
    end
  end

  local function ensure_tempfile()
    if temp_path or temp_open_failed or not spill_to_disk then return end
    if psi.tempfile_path == nil or psi.file_append == nil then
      temp_open_failed = true
      return
    end
    temp_path = psi.tempfile_path("psi-bash-")
    -- Pre-flush whatever we already have buffered.
    local existing = table.concat(buf)
    if #existing > 0 then
      if not psi.file_append(temp_path, existing) then
        temp_open_failed = true
        temp_path = nil
      end
    end
  end

  while true do
    local chunk, done = poll_fn(handle, 50)
    if chunk ~= nil and #chunk > 0 then
      total_bytes = total_bytes + #chunk
      buf[#buf + 1] = chunk
      buf_bytes = buf_bytes + #chunk
      trim_rolling()
      -- Spill once the in-memory limit is exceeded.
      if total_bytes > max_bytes then
        ensure_tempfile()
        if temp_path then
          if not psi.file_append(temp_path, chunk) then
            temp_open_failed = true
          end
        end
      end
      if psi.tool_progress ~= nil then
        psi.tool_progress(tool_call_id, chunk)
      end
    end
    if done then break end
  end

  -- Drain whatever process.c buffered (it may include the head we
  -- already saw — that's fine, we only use this to extract the exit
  -- status; we ignore its `output` field because Lua-side `buf` has the
  -- accurate, untruncated tail.)
  local tail = records.process_result_from_alist(psi.process_finish(handle))
  return {
    rolling = table.concat(buf),
    rolling_bytes = buf_bytes,
    total_bytes = total_bytes,
    status = tail.status,
    temp_file_path = temp_path,
  }
end

-- Run a shell command. Returns a ProcessResult-shaped table.
-- This is the legacy entry point that callers used before the
-- streaming-with-truncation work; it remains backwards-compatible
-- (output is whatever process.c handed us, capped at 256 KiB).
function M.process_result(command, tool_call_id)
  if not sched.in_coroutine() then
    return records.process_result_from_alist(psi.process_run(command))
  end

  local handle, err = psi.process_begin(command)
  if handle == nil then
    return records.process_result_from_alist({
      output = tostring(err or "process_begin failed"),
      status = -1,
      truncated = false,
    })
  end

  while true do
    local chunk, done = sched.proc_poll(handle, 50)
    if chunk ~= nil and #chunk > 0 and psi.tool_progress ~= nil then
      psi.tool_progress(tool_call_id, chunk)
    end
    if done then
      break
    end
  end

  return records.process_result_from_alist(psi.process_finish(handle))
end

function M.process_result_argv(argv, tool_call_id)
  if not sched.in_coroutine() then
    return records.process_result_from_alist(psi.process_run_argv(argv))
  end

  local handle, err = psi.process_begin_argv(argv)
  if handle == nil then
    return records.process_result_from_alist({
      output = tostring(err or "process_begin_argv failed"),
      status = -1,
      truncated = false,
    })
  end

  while true do
    local chunk, done = sched.proc_poll(handle, 50)
    if chunk ~= nil and #chunk > 0 and psi.tool_progress ~= nil then
      psi.tool_progress(tool_call_id, chunk)
    end
    if done then
      break
    end
  end

  return records.process_result_from_alist(psi.process_finish(handle))
end

-- Streamed runner that returns the rolling-buffer output plus a
-- spillover temp-file path (when applicable). Used by tools that
-- want pi-mono-style truncation.
local function run_streaming_with(handle, err, tool_call_id, opts, kind)
  if handle == nil then
    return {
      output = tostring(err or (kind .. " failed")),
      status = -1,
      total_bytes = 0,
      temp_file_path = nil,
    }
  end
  -- Inside a coroutine we yield via sched.proc_poll so the TUI
  -- redraws between reads; outside we drive the same async handle
  -- directly through psi.process_poll, which still blocks but lets
  -- us stream chunks (and spill to disk) instead of relying on the
  -- 256 KiB C-side buffer.
  local poll_fn = sched.in_coroutine() and sched.proc_poll or blocking_poll
  local s = stream(handle, tool_call_id, opts, poll_fn)
  return {
    output = s.rolling,
    status = s.status,
    total_bytes = s.total_bytes,
    temp_file_path = s.temp_file_path,
  }
end

function M.run_streaming(command, tool_call_id, opts)
  local handle, err = psi.process_begin(command)
  return run_streaming_with(handle, err, tool_call_id, opts, "process_begin")
end

function M.run_streaming_argv(argv, tool_call_id, opts)
  local handle, err = psi.process_begin_argv(argv)
  return run_streaming_with(handle, err, tool_call_id, opts, "process_begin_argv")
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

function M.run_tool_argv(tool_name, argv, path, keep_output_on_error, meta)
  local proc = M.process_result_argv(argv, meta and meta.tool_call_id or nil)
  local ok = proc:ok()
  local include_output = keep_output_on_error or ok or (proc.output and #proc.output > 0)
  local extras = {}
  if path then
    extras.path = path
  end
  extras.argv = argv
  extras.status = proc.status
  extras.truncated = proc.truncated
  if include_output then
    extras.output = proc.output or ""
  end
  return records.new_tool_result(ok, tool_name, nil, extras)
end

return M
