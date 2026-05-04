-- psi.utf8_text: UTF-8 helpers shared by the TUI editor, truncation
-- helpers, and any other surface that needs codepoint-aware text
-- handling.
--
-- Cursor / index helpers (prev_cp, next_cp) return byte indices in the
-- 0-based convention used by tui_runtime.state.cursor (i.e. number of
-- bytes before the cursor). Lua's built-in utf8.offset uses 1-based
-- byte positions; we translate at the boundary.
--
-- Cell-width queries delegate to psi.cell_width, which is backed by
-- the public-domain mk_wcwidth implementation in src/core/wcwidth.c.
-- That keeps the Unicode tables in one place — vetted C code reused
-- across hosts — and lets this module stay small. When psi.cell_width
-- isn't available (e.g. ports that haven't linked the C runtime), we
-- fall back to a minimal heuristic: ASCII control = 0, everything
-- non-ASCII conservatively = 1.

local utf8 = require("utf8")

local M = {}

-- ---------------------------------------------------------------------------
-- Cell width
-- ---------------------------------------------------------------------------

local cell_width_fn
if type(psi) == "table" and type(psi.cell_width) == "function" then
  cell_width_fn = psi.cell_width
else
  cell_width_fn = function(cp)
    if cp == nil or cp < 0x20 or cp == 0x7F then
      return 0
    end
    return 1
  end
end

function M.cell_width(cp)
  if cp == nil then
    return 0
  end
  return cell_width_fn(cp)
end

-- ---------------------------------------------------------------------------
-- Cursor / boundary helpers
-- ---------------------------------------------------------------------------

-- Byte index of the codepoint start preceding `pos`. Falls back to
-- pos-1 if utf8.offset can't make sense of the buffer (e.g. mid-edit
-- transient invalid bytes), so the cursor never gets stuck.
function M.prev_cp(text, pos)
  pos = pos or 0
  if pos <= 0 then
    return 0
  end
  if pos > #text then
    pos = #text
  end
  local ok, off = pcall(utf8.offset, text, -1, pos + 1)
  if ok and type(off) == "number" then
    return off - 1
  end
  return pos - 1
end

-- Byte index of the codepoint start following the codepoint at `pos`.
function M.next_cp(text, pos)
  pos = pos or 0
  if pos < 0 then
    pos = 0
  end
  if pos >= #text then
    return #text
  end
  local ok, off = pcall(utf8.offset, text, 2, pos + 1)
  if ok and type(off) == "number" then
    return off - 1
  end
  return pos + 1
end

-- Return the codepoint that starts at byte index `pos` (0-based), or
-- nil if `pos` doesn't sit on a codepoint boundary.
function M.codepoint_at(text, pos)
  if pos < 0 or pos >= #text then
    return nil
  end
  local ok, cp = pcall(utf8.codepoint, text, pos + 1)
  if ok then
    return cp
  end
  return nil
end

-- Return the slice covering exactly the codepoint that starts at
-- byte index `pos`, or "" if `pos` is at end of string.
function M.codepoint_slice(text, pos)
  if pos < 0 or pos >= #text then
    return ""
  end
  return text:sub(pos + 1, M.next_cp(text, pos))
end

-- Display width of a string in terminal cells. Invalid UTF-8 falls
-- through as one cell per byte, matching the previous best-effort
-- behavior.
function M.string_width(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  local width = 0
  local pos = 1
  while pos <= #text do
    local ok, cp = pcall(utf8.codepoint, text, pos)
    if not ok then
      width = width + 1
      pos = pos + 1
    else
      width = width + cell_width_fn(cp)
      local ok2, nxt = pcall(utf8.offset, text, 2, pos)
      if not ok2 or type(nxt) ~= "number" then
        pos = pos + 1
      else
        pos = nxt
      end
    end
  end
  return width
end

-- ---------------------------------------------------------------------------
-- Truncation
-- ---------------------------------------------------------------------------

-- Take the first whole codepoints whose total byte length is <=
-- max_bytes. The cut never lands in the middle of a multi-byte
-- sequence — if it would, we step back to the previous codepoint
-- start.
function M.safe_head(text, max_bytes)
  if type(text) ~= "string" or max_bytes == nil or max_bytes < 0 then
    return text or ""
  end
  if #text <= max_bytes then
    return text
  end
  local pos = max_bytes + 1
  while pos > 1 do
    local b = text:byte(pos)
    if b == nil or (b & 0xC0) ~= 0x80 then
      break
    end
    pos = pos - 1
  end
  return text:sub(1, pos - 1)
end

-- Take the trailing whole codepoints whose total byte length is <=
-- max_bytes. Mirrors safe_head.
function M.safe_tail(text, max_bytes)
  if type(text) ~= "string" or max_bytes == nil or max_bytes < 0 then
    return text or ""
  end
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

-- Take the first `max_chars` codepoints from `text`. Returns the
-- prefix and a boolean indicating whether the input was truncated.
function M.head_chars(text, max_chars)
  if type(text) ~= "string" or text == "" then
    return text or "", false
  end
  if max_chars == nil or max_chars < 0 then
    return text, false
  end
  local ok, len = pcall(utf8.len, text)
  if ok and type(len) == "number" and len <= max_chars then
    return text, false
  end
  local ok2, off = pcall(utf8.offset, text, max_chars + 1)
  if not ok2 or type(off) ~= "number" then
    return M.safe_head(text, max_chars), true
  end
  return text:sub(1, off - 1), true
end

return M
