-- psi.notice: single sink for out-of-band operational messages
-- (auto-compaction progress, provider/auth failures, HTTP errors).
--
-- The problem this solves: providers historically called io.stderr:write
-- directly. In headless/CLI mode that is fine, but under the interactive
-- TUI a raw write lands in the middle of the alt-screen render and
-- scrambles the display (the "auto-compacting failed" / auth-failure
-- lines the user reported).
--
-- notice.emit routes through psi.events under the "notice" event. The
-- TUI subscribes and turns each notice into a proper transcript entry or
-- status line. When no subscriber is registered (headless), we fall back
-- to io.stderr:write so nothing is silently dropped.

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

  -- Headless fallback: preserve the previous stderr behavior.
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
