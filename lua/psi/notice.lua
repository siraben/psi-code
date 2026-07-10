-- Sink for out-of-band operational messages. Emits the "notice" event
-- when a subscriber exists (TUI); otherwise falls back to io.stderr.

local M = {}

local function has_tui_sink()
  if not (psi.events and psi.events.handlers) then
    return false
  end
  local ok, list = pcall(psi.events.handlers, "notice")
  return ok and type(list) == "table" and #list > 0
end

-- level: "info" | "warn" | "error" (defaults to "info")
function M.emit(text, level)
  text = tostring(text or "")
  if text == "" then
    return
  end
  level = level or "info"

  if has_tui_sink() and psi.events and psi.events.emit then
    psi.events.emit("notice", { text = text, level = level })
    return
  end

  io.stderr:write(text .. "\n")
end

function M.info(text)
  M.emit(text, "info")
end

function M.warn(text)
  M.emit(text, "warn")
end

function M.error(text)
  M.emit(text, "error")
end

return M
