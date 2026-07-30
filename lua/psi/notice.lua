-- Frontend-owned sink for out-of-band operational messages.
--
-- A TUI cannot infer terminal ownership from event subscribers: /reload
-- clears the event bus, and unrelated subscribers are not terminal owners.
-- The active frontend therefore attaches an explicit sink. With no sink,
-- notices retain the CLI behavior of writing to stderr.

local M = {}
local active_sink = nil
local Queue = {}
Queue.__index = Queue

function Queue:push(record)
  record = type(record) == "table" and record or {}
  local text = tostring(record.text or "")
  if text == "" then
    return false
  end
  if #text > self.max_text then
    local suffix = "\n[notice truncated]"
    if self.max_text > #suffix then
      text = text:sub(1, self.max_text - #suffix) .. suffix
    else
      text = text:sub(1, self.max_text)
    end
  end
  if #self.records >= self.max_count or self.bytes + #text > self.max_bytes then
    self.overflow = true
    return false
  end
  self.records[#self.records + 1] = {
    text = text,
    level = record.level or "info",
    source = record.source,
    code = record.code,
  }
  self.bytes = self.bytes + #text
  return true
end

function Queue:drain()
  local records = self.records
  local overflow = self.overflow
  self.records = {}
  self.bytes = 0
  self.overflow = false
  return records, overflow
end

function Queue:count()
  return #self.records
end

function M.new_queue(opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    records = {},
    bytes = 0,
    overflow = false,
    max_count = math.max(1, tonumber(opts.max_count) or 64),
    max_bytes = math.max(1, tonumber(opts.max_bytes) or 64 * 1024),
    max_text = math.max(1, tonumber(opts.max_text) or 8 * 1024),
  }, Queue)
end

-- level: "info" | "warn" | "error" (defaults to "info")
function M.emit(text, level, metadata)
  text = tostring(text or "")
  if text == "" then
    return false
  end
  level = level or "info"

  if active_sink ~= nil then
    local record = {
      text = text,
      level = level,
    }
    if type(metadata) == "table" then
      record.source = metadata.source
      record.code = metadata.code
    end
    local ok = pcall(active_sink.callback, record)
    if ok then
      return true
    end
  end

  io.stderr:write(text .. "\n")
  return false
end

-- Install one terminal-owning frontend sink. The returned token must be
-- supplied to clear_sink so stale cleanup cannot detach a newer frontend.
function M.set_sink(sink)
  assert(type(sink) == "function", "notice sink must be a function")
  local token = {}
  active_sink = {
    token = token,
    callback = sink,
  }
  return token
end

function M.clear_sink(token)
  if active_sink == nil or token == nil then
    return false
  end
  if active_sink.token ~= token then
    return false
  end
  active_sink = nil
  return true
end

function M.info(text, metadata)
  M.emit(text, "info", metadata)
end

function M.warn(text, metadata)
  M.emit(text, "warn", metadata)
end

function M.error(text, metadata)
  M.emit(text, "error", metadata)
end

return M
