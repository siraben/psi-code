-- psi.stream_parser: chunked line, SSE, and JSONL framing helpers.

local M = {}

local function strip_cr(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end
  return line
end

function M.line_parser()
  return { line = {} }
end

function M.push_lines(parser, chunk, on_line)
  local start = 1
  local len = #chunk
  while start <= len do
    local nl = chunk:find("\n", start, true)
    if not nl then
      parser.line[#parser.line + 1] = chunk:sub(start)
      break
    end
    parser.line[#parser.line + 1] = chunk:sub(start, nl - 1)
    local line = strip_cr(table.concat(parser.line))
    parser.line = {}
    on_line(line)
    start = nl + 1
  end
end

function M.sse_parser()
  return {
    line = {},
    pending_event = nil,
    pending_data = nil,
    pending = {},
  }
end

function M.push_sse(parser, chunk, opts)
  opts = opts or {}
  M.push_lines(parser, chunk, function(line)
    if line:sub(1, 6) == "event:" then
      -- The space after the SSE field colon is optional; tolerate both
      -- "event: foo" and "event:foo".
      local ev = line:sub(7)
      if ev:sub(1, 1) == " " then
        ev = ev:sub(2)
      end
      parser.pending_event = ev
    elseif line:sub(1, 6) == "data: " then
      local data = line:sub(7)
      if opts.multi_data then
        parser.pending[#parser.pending + 1] = data
      else
        parser.pending_data = data
      end
    elseif line:sub(1, 5) == "data:" then
      local data = line:sub(6)
      if data:sub(1, 1) == " " then
        data = data:sub(2)
      end
      if opts.multi_data then
        parser.pending[#parser.pending + 1] = data
      else
        parser.pending_data = data
      end
    elseif line == "" then
      local data = parser.pending_data
      if opts.multi_data then
        data = table.concat(parser.pending, "\n")
        parser.pending = {}
      end
      if data ~= nil and data ~= "" then
        opts.on_event(parser.pending_event, data)
      end
      parser.pending_event = nil
      parser.pending_data = nil
    end
  end)
end

return M
