-- psi.tui: helpers for the C-side TUI to render things that depend
-- on Lua-owned state (session, context, usage). Kept tiny and
-- side-effect-free so the C layer can call them on every redraw.

local context = require("psi.context")
local prelude = require("psi.prelude")

local M = {}

local function short_id(id)
  if type(id) ~= "string" or id == "" then
    return "-"
  end
  return id:sub(1, 8)
end

-- Format a pi-ish status line. `arg_json` is a JSON object emitted by
-- the C TUI: {model=string, busy=bool, scroll=int}.
-- Returns a single string with fields separated by two spaces.
function M.status_line(arg_json)
  local arg = prelude.safe_json_decode(arg_json, {})
  local model  = arg.model or "?"
  local busy   = arg.busy
  local scroll = tonumber(arg.scroll) or 0

  local parts = {}
  parts[#parts + 1] = "session:" .. short_id(psi.session_id())
  parts[#parts + 1] = "model:" .. model
  parts[#parts + 1] = "msg:" .. tostring(psi.session_message_count())

  local last = context.last_usage()
  if last and last.total and last.total > 0 then
    local window = context.context_window(model)
    local pct = math.floor((last.total / window) * 100)
    parts[#parts + 1] = string.format("ctx:%d%% (%d/%d)", pct, last.total, window)
  end

  if scroll > 0 then
    parts[#parts + 1] = "scroll:" .. tostring(scroll)
  end
  if busy then
    parts[#parts + 1] = "working…"
  end
  return table.concat(parts, "  ")
end

-- Short help line for the footer. Content depends on mode.
function M.footer_hint(arg_json)
  local arg = prelude.safe_json_decode(arg_json, {})
  if arg.busy then
    return "Esc abort current turn"
  end
  if (tonumber(arg.scroll) or 0) > 0 then
    return "↑↓ scroll  PgUp/PgDn page  Home/End jump  Enter=submit  /help  /quit"
  end
  return "Enter submit  ↑↓ scroll  /help  /quit"
end

return M
