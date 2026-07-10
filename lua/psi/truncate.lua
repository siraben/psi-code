-- psi.truncate: shared output-truncation helpers.
--
-- Ported from pi-mono `packages/coding-agent/src/core/tools/truncate.ts`.
-- Two independent limits — whichever is hit first wins:
--   * line limit  (default 2000 lines)
--   * byte limit  (default 50 KiB)
-- truncate_head keeps the first N (good for files / search results),
-- truncate_tail keeps the last N (good for shell output where errors
-- live at the end).
--
-- Neither truncator returns partial lines except for one tail edge
-- case: when a single trailing line itself exceeds the byte cap we
-- return its tail and flag `last_line_partial=true`, mirroring pi.
--
-- truncate_line is for clipping individual long match lines (grep).

local M = {}

M.DEFAULT_MAX_LINES = 2000
M.DEFAULT_MAX_BYTES = 50 * 1024 -- 50 KiB
M.GREP_MAX_LINE_LENGTH = 500

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function split_lines(text)
  local lines = {}
  text = text or ""
  local start = 1
  local len = #text
  while start <= len + 1 do
    local nl = text:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  if len > 0 and text:sub(len, len) == "\n" and lines[#lines] == "" then
    lines[#lines] = nil
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

-- Format a byte count as a human-readable size, matching pi.
function M.format_size(bytes)
  bytes = bytes or 0
  if bytes < 1024 then
    return string.format("%dB", bytes)
  elseif bytes < 1024 * 1024 then
    return string.format("%.1fKB", bytes / 1024)
  else
    return string.format("%.1fMB", bytes / (1024 * 1024))
  end
end

-- Walk back to a UTF-8 character boundary so a tail slice doesn't
-- start in the middle of a multi-byte sequence. Bytes 0x80–0xBF are
-- continuation bytes; advance until we land on a leading byte.
local function utf8_safe_tail(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  local start = #text - max_bytes + 1
  while start <= #text do
    local b = text:byte(start)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    start = start + 1
  end
  return text:sub(start)
end

local function empty_result(content, total_lines, total_bytes, max_lines, max_bytes)
  return {
    content = content,
    truncated = false,
    truncated_by = nil,
    total_lines = total_lines,
    total_bytes = total_bytes,
    output_lines = total_lines,
    output_bytes = total_bytes,
    last_line_partial = false,
    first_line_exceeds_limit = false,
    max_lines = max_lines,
    max_bytes = max_bytes,
  }
end

-- ---------------------------------------------------------------------------
-- truncate_head: keep first N lines/bytes. Used by read/grep/ls/find.
-- ---------------------------------------------------------------------------

function M.truncate_head(content, options)
  options = options or {}
  local max_lines = options.max_lines or M.DEFAULT_MAX_LINES
  local max_bytes = options.max_bytes or M.DEFAULT_MAX_BYTES

  content = content or ""
  local total_bytes = #content
  local lines = split_lines(content)
  local total_lines = #lines

  if total_lines <= max_lines and total_bytes <= max_bytes then
    return empty_result(content, total_lines, total_bytes, max_lines, max_bytes)
  end

  -- Edge case: first line alone exceeds byte limit.
  if #lines[1] > max_bytes then
    return {
      content = "",
      truncated = true,
      truncated_by = "bytes",
      total_lines = total_lines,
      total_bytes = total_bytes,
      output_lines = 0,
      output_bytes = 0,
      last_line_partial = false,
      first_line_exceeds_limit = true,
      max_lines = max_lines,
      max_bytes = max_bytes,
    }
  end

  local kept = {}
  local kept_bytes = 0
  local truncated_by = "lines"

  for i = 1, math.min(#lines, max_lines) do
    local line = lines[i]
    local line_bytes = #line + (i > 1 and 1 or 0) -- +1 for "\n" separator
    if kept_bytes + line_bytes > max_bytes then
      truncated_by = "bytes"
      break
    end
    kept[#kept + 1] = line
    kept_bytes = kept_bytes + line_bytes
  end

  if #kept >= max_lines and kept_bytes <= max_bytes then
    truncated_by = "lines"
  end

  local out = table.concat(kept, "\n")
  return {
    content = out,
    truncated = true,
    truncated_by = truncated_by,
    total_lines = total_lines,
    total_bytes = total_bytes,
    output_lines = #kept,
    output_bytes = #out,
    last_line_partial = false,
    first_line_exceeds_limit = false,
    max_lines = max_lines,
    max_bytes = max_bytes,
  }
end

-- ---------------------------------------------------------------------------
-- truncate_tail: keep last N lines/bytes. Used by bash so errors at the
-- end survive truncation.
-- ---------------------------------------------------------------------------

function M.truncate_tail(content, options)
  options = options or {}
  local max_lines = options.max_lines or M.DEFAULT_MAX_LINES
  local max_bytes = options.max_bytes or M.DEFAULT_MAX_BYTES

  content = content or ""
  local total_bytes = #content
  local lines = split_lines(content)
  local total_lines = #lines

  if total_lines <= max_lines and total_bytes <= max_bytes then
    return empty_result(content, total_lines, total_bytes, max_lines, max_bytes)
  end

  local kept = {}
  local kept_bytes = 0
  local truncated_by = "lines"
  local last_line_partial = false

  for i = #lines, 1, -1 do
    if #kept >= max_lines then
      break
    end
    local line = lines[i]
    local line_bytes = #line + (#kept > 0 and 1 or 0)
    if kept_bytes + line_bytes > max_bytes then
      truncated_by = "bytes"
      if #kept == 0 then
        local sliced = utf8_safe_tail(line, max_bytes)
        table.insert(kept, 1, sliced)
        kept_bytes = #sliced
        last_line_partial = true
      end
      break
    end
    table.insert(kept, 1, line)
    kept_bytes = kept_bytes + line_bytes
  end

  if #kept >= max_lines and kept_bytes <= max_bytes then
    truncated_by = "lines"
  end

  local out = table.concat(kept, "\n")
  return {
    content = out,
    truncated = true,
    truncated_by = truncated_by,
    total_lines = total_lines,
    total_bytes = total_bytes,
    output_lines = #kept,
    output_bytes = #out,
    last_line_partial = last_line_partial,
    first_line_exceeds_limit = false,
    max_lines = max_lines,
    max_bytes = max_bytes,
  }
end

-- Clip a single line to `max_chars` characters, adding a marker.
function M.truncate_line(line, max_chars)
  max_chars = max_chars or M.GREP_MAX_LINE_LENGTH
  line = line or ""
  if #line <= max_chars then
    return line, false
  end
  return line:sub(1, max_chars) .. "... [truncated]", true
end

-- ---------------------------------------------------------------------------
-- Back-compat helpers (still used by read.lua + truncate.notice).
-- ---------------------------------------------------------------------------

function M.by_lines(text, offset, limit)
  local lines = split_lines(text)
  local total = #lines
  offset = math.max(0, tonumber(offset) or 0)
  limit = math.max(1, tonumber(limit) or total)

  local start = math.min(total + 1, offset + 1)
  local stop = math.min(total, start + limit - 1)
  local out = {}
  for i = start, stop do
    out[#out + 1] = lines[i]
  end

  local truncated = start > 1 or stop < total
  return table.concat(out, "\n"),
    {
      total_lines = total,
      start_line = total == 0 and 0 or start,
      end_line = stop,
      truncated = truncated,
      next_offset = stop < total and stop or nil,
    }
end

function M.bytes(text, max_bytes, mode)
  text = text or ""
  max_bytes = tonumber(max_bytes) or #text
  if max_bytes <= 0 or #text <= max_bytes then
    return text, false
  end
  if mode == "tail" then
    return utf8_safe_tail(text, max_bytes), true
  end
  return text:sub(1, max_bytes), true
end

function M.notice(meta)
  if not meta or not meta.truncated then
    return nil
  end
  local parts = {
    "[Showing lines ",
    tostring(meta.start_line),
    "-",
    tostring(meta.end_line),
    " of ",
    tostring(meta.total_lines),
    ".",
  }
  if meta.next_offset then
    parts[#parts + 1] = " Use offset="
    parts[#parts + 1] = tostring(meta.next_offset)
    parts[#parts + 1] = " to continue."
  end
  parts[#parts + 1] = "]"
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Notice builders that work off a `truncate_head` / `truncate_tail` result.
-- ---------------------------------------------------------------------------

-- Notice for head-truncated output (read/grep/ls/find).
-- `extras` may carry { full_output_path = "/tmp/..." } for a "Full output:"
-- suffix, mirroring pi-mono's bash spillover hint.
function M.head_notice(result, extras)
  if not result or not result.truncated then
    return nil
  end
  extras = extras or {}
  if result.first_line_exceeds_limit then
    return string.format("[First line exceeds %s limit]", M.format_size(result.max_bytes))
  end
  local parts = {}
  if result.truncated_by == "lines" then
    parts[#parts + 1] = string.format(
      "Truncated: showing %d of %d lines (%d line limit)",
      result.output_lines,
      result.total_lines,
      result.max_lines
    )
  else
    parts[#parts + 1] = string.format(
      "Truncated: %d lines shown (%s limit)",
      result.output_lines,
      M.format_size(result.max_bytes)
    )
  end
  if extras.full_output_path then
    parts[#parts + 1] = "Full output: " .. extras.full_output_path
  end
  return "[" .. table.concat(parts, ". ") .. "]"
end

-- Notice for tail-truncated output (bash).
function M.tail_notice(result, extras)
  if not result or not result.truncated then
    return nil
  end
  extras = extras or {}
  local start_line = result.total_lines - result.output_lines + 1
  local end_line = result.total_lines
  local parts = {}
  if result.last_line_partial then
    parts[#parts + 1] =
      string.format("Showing last %s of line %d", M.format_size(result.output_bytes), end_line)
  elseif result.truncated_by == "lines" then
    parts[#parts + 1] =
      string.format("Showing lines %d-%d of %d", start_line, end_line, result.total_lines)
  else
    parts[#parts + 1] = string.format(
      "Showing lines %d-%d of %d (%s limit)",
      start_line,
      end_line,
      result.total_lines,
      M.format_size(result.max_bytes)
    )
  end
  if extras.full_output_path then
    parts[#parts + 1] = "Full output: " .. extras.full_output_path
  end
  return "[" .. table.concat(parts, ". ") .. "]"
end

return M
