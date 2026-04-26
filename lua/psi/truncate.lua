-- psi.truncate: shared output truncation helpers.

local M = {}

local function split_lines(text)
  local lines = {}
  text = text or ""
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  return lines
end

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
  return table.concat(out, "\n"), {
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
    return text:sub(#text - max_bytes + 1), true
  end
  return text:sub(1, max_bytes), true
end

function M.notice(meta)
  if not meta or not meta.truncated then return nil end
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

return M
