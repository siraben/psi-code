-- psi.tui: helpers for the C-side TUI to render things that depend
-- on Lua-owned state (session, context, usage). Kept tiny and
-- side-effect-free so the C layer can call them on every redraw.

local context = require("psi.context")
local keybindings = require("psi.keybindings")
local prelude = require("psi.prelude")

local M = {}

local function action(name, arg)
  return { action = name, arg = arg }
end

-- Status-line hooks. Extensions can register fns that return a short
-- string appended to the TUI status line. Called on every redraw, so
-- they must be cheap and side-effect-free. Return nil / "" to skip.
--
-- Example:
--   psi.tui.register_status_hook(function()
--     return "ext:tps " .. last_tps_value
--   end)
--
-- This is the lightest-weight TUI widget slot: no C plumbing, works
-- in the existing single status-line layout, and is automatically
-- suppressed when a status message (set via psi_tui_set_status) is
-- active. For a dedicated row with arbitrary content, wait for a
-- real widget API — this is the pi-gap shim.
local status_hooks = {}

function M.register_status_hook(fn)
  status_hooks[#status_hooks + 1] = fn
end

function M.clear_status_hooks()
  status_hooks = {}
end

-- High-level TUI key policy. C normalizes terminal-specific ncurses
-- input into semantic key names ("enter", "shift-enter", "alt-b",
-- "ctrl-d", "text", ...), then Lua decides what that key means in the
-- current editor state. The host still owns the terminal mechanics:
-- raw escape parsing, cursor placement, redraw cadence, and actually
-- mutating the input buffer.
function M.handle_key(arg)
  arg = type(arg) == "table" and arg or {}
  local key = arg.key
  local busy = not not arg.busy
  local input_length = tonumber(arg.input_length) or 0
  local text = arg.text or ""

  if key == "text" then
    if text ~= "" then
      return action("insert", text)
    end
    return nil
  end

  if keybindings.matches(key, "tui.input.submit") then
    if not busy and input_length > 0 then
      return action("submit")
    end
    return nil
  end

  if keybindings.matches(key, "tui.input.newLine") then
    return action("insert", "\n")
  end
  if keybindings.matches(key, "tui.editor.deleteCharBackward") then
    return action("delete-backward")
  end
  if input_length == 0 and keybindings.matches(key, "app.exit") then
    if not busy then
      return action("quit")
    end
    return nil
  end
  if keybindings.matches(key, "tui.editor.deleteCharForward") then
    return action("delete-forward")
  end
  if keybindings.matches(key, "tui.editor.deleteWordBackward") then
    return action("delete-word-backward")
  end
  if keybindings.matches(key, "tui.editor.deleteWordForward") then
    return action("delete-word-forward")
  end
  if keybindings.matches(key, "tui.editor.cursorWordLeft") then
    return action("move-word-left")
  end
  if keybindings.matches(key, "tui.editor.cursorWordRight") then
    return action("move-word-right")
  end
  if keybindings.matches(key, "tui.editor.deleteToLineEnd") then
    return action("kill-end")
  end
  if keybindings.matches(key, "tui.input.clear") then
    return action("kill-start")
  end
  if keybindings.matches(key, "tui.editor.cursorLeft") then
    return action("move-left")
  end
  if keybindings.matches(key, "tui.editor.cursorRight") then
    return action("move-right")
  end
  if keybindings.matches(key, "tui.editor.cursorLineStart") then
    return action("move-home")
  end
  if keybindings.matches(key, "tui.editor.cursorLineEnd") then
    return action("move-end")
  end
  if keybindings.matches(key, "tui.transcript.lineUp") then
    return action("scroll", "line-up")
  end
  if keybindings.matches(key, "tui.transcript.lineDown") then
    return action("scroll", "line-down")
  end
  if keybindings.matches(key, "tui.transcript.pageUp") then
    return action("scroll", "page-up")
  end
  if keybindings.matches(key, "tui.transcript.pageDown") then
    return action("scroll", "page-down")
  end
  if keybindings.matches(key, "app.redraw") then
    return action("redraw")
  end
  if keybindings.matches(key, "app.suspend") then
    return action("suspend")
  end

  if keybindings.matches(key, "app.interrupt") then
    if busy then
      return action("abort")
    end
    return nil
  end

  return nil
end

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
  -- Prefer the runtime model override (set via psi.agent.set_model)
  -- over whatever C passed in, so a live `/model` swap or an
  -- extension-driven change is reflected in the footer without a
  -- restart. require() is resolved lazily to avoid a boot-time
  -- cycle (agent ↔ prompt ↔ tools ↔ tui).
  local ok, agent = pcall(require, "psi.agent")
  local resolved = ok and agent.model_descriptor(arg.model)
  local model = (resolved and resolved.id) or arg.model or "?"
  local context_window = tonumber(arg.context_window)
    or (resolved and tonumber(resolved.context_window))
  local busy = arg.busy
  local scroll = tonumber(arg.scroll) or 0

  local parts = {}
  parts[#parts + 1] = "session:" .. short_id(psi.session_id())
  parts[#parts + 1] = "model:" .. model
  parts[#parts + 1] = "msg:" .. tostring(psi.session_message_count())

  local estimate = context.estimate_context_tokens()
  if estimate and estimate.tokens and estimate.tokens > 0 then
    local window = context_window or context.context_window(model)
    local pct = (estimate.tokens / window) * 100
    parts[#parts + 1] = string.format("ctx:%.1f%% (%d/%d)", pct, estimate.tokens, window)
  end

  if scroll > 0 then
    parts[#parts + 1] = "scroll:" .. tostring(scroll)
  end
  if busy then
    parts[#parts + 1] = "working…"
  end
  for _, fn in ipairs(status_hooks) do
    local ok_hook, extra = pcall(fn)
    if ok_hook and type(extra) == "string" and extra ~= "" then
      parts[#parts + 1] = extra
    end
  end
  return table.concat(parts, "  ")
end

-- Short help line for the footer. Content depends on mode.
function M.footer_hint(arg_json)
  return keybindings.footer_hint(arg_json)
end

return M
