-- psi.tui_status: status-line and footer helpers for --tui mode.
-- Renders the rich status line (cwd / model / session / token usage)
-- and the keybinding hint footer. Kept tiny and side-effect-free so
-- the TUI runtime can call them on every redraw. The full TUI state
-- machine and key dispatch live in psi.tui_runtime.

local ansi = require("psi.ansi")
local context = require("psi.context")
local keybindings = require("psi.keybindings")
local prelude = require("psi.prelude")
local settings = require("psi.settings_manager")
local tui_text = require("psi.tui_text")

local M = {}
local BAR_SPLIT = string.char(31)
local NON_PRINTABLE_ASCII_PATTERN = "[^\32-\126]"
local BYTE_ESC = 27
local UTF8_CONTINUATION_MASK = 0xC0
local UTF8_CONTINUATION_TAG = 0x80
local busy_rng_seeded = false
local enabled_setting
M._visible_width_cache = { entries = 0 }

local DEFAULT_BUSY_LABELS = {
  { label = "working", weight = 1 },
  { label = "thinking", weight = 1 },
  { label = "reading", weight = 1 },
  { label = "writing", weight = 1 },
  { label = "editing", weight = 1 },
  { label = "checking", weight = 1 },
  { label = "running", weight = 1 },
  { label = "reviewing", weight = 1 },
}

local function action(name, arg)
  return { action = name, arg = arg }
end

local key_handlers = {}
local next_key_handler_id = 0

function M.register_key_handler(fn)
  if type(fn) ~= "function" then
    return false, "key handler must be a function"
  end
  next_key_handler_id = next_key_handler_id + 1
  key_handlers[#key_handlers + 1] = { id = next_key_handler_id, fn = fn }
  return next_key_handler_id
end

function M.unregister_key_handler(id)
  for index, handler in ipairs(key_handlers) do
    if handler.id == id then
      table.remove(key_handlers, index)
      return true
    end
  end
  return false
end

function M.clear_key_handlers()
  key_handlers = {}
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
local next_status_hook_id = 0

function M.register_status_hook(fn)
  if type(fn) ~= "function" then
    return false, "status hook must be a function"
  end
  next_status_hook_id = next_status_hook_id + 1
  status_hooks[#status_hooks + 1] = { id = next_status_hook_id, fn = fn }
  return next_status_hook_id
end

function M.unregister_status_hook(id)
  for index, hook in ipairs(status_hooks) do
    if hook.id == id then
      table.remove(status_hooks, index)
      return true
    end
  end
  return false
end

function M.clear_status_hooks()
  status_hooks = {}
end

local command_action_handlers = {}

function M.register_command_action_handler(kind, fn)
  if type(kind) ~= "string" or kind == "" or type(fn) ~= "function" then
    return false, "command action handler requires a kind and function"
  end
  command_action_handlers[kind] = fn
  return true
end

function M.unregister_command_action_handler(kind)
  command_action_handlers[kind] = nil
end

function M.handle_command_action(action_value, action_context)
  if type(action_value) ~= "table" then
    return false
  end
  local handler = command_action_handlers[action_value.kind]
  if handler == nil then
    return false
  end
  local ok, handled = pcall(handler, action_value.payload, action_context or {})
  if not ok then
    io.stderr:write("psi: TUI command action handler failed: " .. tostring(handled) .. "\n")
    return true
  end
  return handled ~= false
end

local startup_hooks = {}

function M.register_startup_hook(name, fn)
  if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
    return false, "startup hook requires a name and function"
  end
  startup_hooks[name] = fn
  return true
end

function M.unregister_startup_hook(name)
  startup_hooks[name] = nil
end

function M.run_startup_hooks(startup_context)
  for name, fn in pairs(startup_hooks) do
    local ok, err = pcall(fn, startup_context or {})
    if not ok then
      io.stderr:write("psi: TUI startup hook " .. name .. " failed: " .. tostring(err) .. "\n")
    end
  end
end

local clipboard_writers = {}
local next_clipboard_writer_id = 0

function M.register_clipboard_writer(fn)
  if type(fn) ~= "function" then
    return false, "clipboard writer must be a function"
  end
  next_clipboard_writer_id = next_clipboard_writer_id + 1
  clipboard_writers[#clipboard_writers + 1] = { id = next_clipboard_writer_id, fn = fn }
  return next_clipboard_writer_id
end

function M.unregister_clipboard_writer(id)
  for index, writer in ipairs(clipboard_writers) do
    if writer.id == id then
      table.remove(clipboard_writers, index)
      return true
    end
  end
  return false
end

function M.clear_clipboard_writers()
  clipboard_writers = {}
end

function M.write_clipboard(text, clipboard_context)
  clipboard_context = type(clipboard_context) == "table" and clipboard_context or {}
  if clipboard_context.disabled then
    return false
  end
  for _, writer in ipairs(clipboard_writers) do
    local ok, handled = pcall(writer.fn, text or "", clipboard_context)
    if ok and handled ~= false then
      return true
    end
    if not ok then
      io.stderr:write("psi: TUI clipboard writer failed: " .. tostring(handled) .. "\n")
    end
  end
  return false
end

-- High-level TUI key policy. C normalizes terminal-specific
-- input into semantic key names ("enter", "shift-enter", "alt-b",
-- "ctrl-d", "text", ...), then Lua decides what that key means in the
-- current editor state. Lua owns editor state and rendering policy.
function M.handle_key(arg)
  arg = type(arg) == "table" and arg or {}
  local key = arg.key
  local busy = not not arg.busy
  local input_length = tonumber(arg.input_length) or 0
  local text = arg.text or ""

  for _, handler in ipairs(key_handlers) do
    local ok, result = pcall(handler.fn, arg)
    if ok and result ~= nil then
      return result
    end
    if not ok then
      io.stderr:write("psi: TUI key handler failed: " .. tostring(result) .. "\n")
    end
  end

  if key == "text" then
    if text ~= "" then
      return action("insert", text)
    end
    return nil
  end

  if keybindings.matches(key, "tui.input.submit") then
    if input_length > 0 then
      return action("submit")
    end
    return nil
  end

  if keybindings.matches(key, "tui.input.newLine") then
    return action("insert", "\n")
  end
  if (tonumber(arg.queue_count) or 0) > 0 and keybindings.matches(key, "tui.queue.restore") then
    return action("queue-restore")
  end
  if busy and keybindings.matches(key, "tui.queue.previous") then
    return action("queue-navigate", "previous")
  end
  if busy and keybindings.matches(key, "tui.queue.next") then
    return action("queue-navigate", "next")
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
  if not busy and keybindings.matches(key, "tui.input.reverseSearch") then
    return action("history-search")
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
  if key == "wheel-up" then
    return action("scroll", "line-up")
  end
  if key == "wheel-down" then
    return action("scroll", "line-down")
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

local function format_elapsed(total_seconds)
  local hours
  local minutes
  local seconds

  total_seconds = math.max(0, tonumber(total_seconds) or 0)
  hours = math.floor(total_seconds / 3600)
  minutes = math.floor((total_seconds % 3600) / 60)
  seconds = total_seconds % 60

  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
  end
  return string.format("%d:%02d", minutes, seconds)
end

local function queue_preview(text)
  text = tostring(text or "")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

local function queue_preview_all(agent)
  if type(agent.pending_messages) ~= "function" then
    return ""
  end
  local pieces = {}
  for _, item in ipairs(agent.pending_messages() or {}) do
    local text = queue_preview(item and item.text or "")
    if text ~= "" then
      pieces[#pieces + 1] = text
    end
  end
  return table.concat(pieces, " | ")
end

local function label(text)
  return ansi.color("2", tostring(text or ""))
end

local function value(text)
  return ansi.color("37", tostring(text or ""))
end

local function accent(text)
  return ansi.color("36", tostring(text or ""))
end

local function utf8_chars(text)
  local chars = {}
  text = tostring(text or "")
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  return chars
end

local function shimmer_text(text, phase)
  if not enabled_setting("tui.busy_glisten", "PSI_BUSY_GLISTEN", true) then
    return accent(text)
  end

  local chars = utf8_chars(text)
  if #chars == 0 then
    return ""
  end

  local sweep = ((tonumber(phase) or 0) % (#chars + 4)) - 1
  local out = {}
  for index, ch in ipairs(chars) do
    local distance = math.abs(index - sweep)
    if distance == 0 then
      out[#out + 1] = ansi.bold(ansi.color("96", ch))
    elseif distance == 1 then
      out[#out + 1] = ansi.color("96", ch)
    else
      out[#out + 1] = accent(ch)
    end
  end
  return table.concat(out)
end

local function sep()
  return label("  •  ")
end

local function pair(key, val, use_accent)
  return label(key) .. " " .. ((use_accent and accent or value)(val))
end

local function seed_busy_rng()
  if busy_rng_seeded then
    return
  end
  math.randomseed(os.time(), math.floor((os.clock() % 1) * 1000000))
  math.random()
  math.random()
  busy_rng_seeded = true
end

local function configured_busy_labels()
  local configured = settings.get("tui.busy_labels", nil)
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" then
    local labels = {}
    for _, label_text in ipairs(configured) do
      if type(label_text) == "string" and label_text ~= "" then
        labels[#labels + 1] = label_text
      end
    end
    if #labels > 0 then
      return labels
    end
  end
  return nil
end

local function default_busy_label()
  local total = 0
  for _, entry in ipairs(DEFAULT_BUSY_LABELS) do
    total = total + (tonumber(entry.weight) or 0)
  end
  if total <= 0 then
    return "working"
  end
  local roll = math.random(total)
  local cumulative = 0
  for _, entry in ipairs(DEFAULT_BUSY_LABELS) do
    cumulative = cumulative + entry.weight
    if roll <= cumulative then
      return entry.label
    end
  end
  return DEFAULT_BUSY_LABELS[#DEFAULT_BUSY_LABELS].label
end

enabled_setting = function(path, env_name, default_value)
  local setting_value = settings.get(path, nil)
  if setting_value == nil and env_name ~= nil then
    setting_value = os.getenv(env_name)
  end
  if setting_value == nil then
    return default_value
  end
  if type(setting_value) == "boolean" then
    return setting_value
  end
  if type(setting_value) == "number" then
    return setting_value ~= 0
  end
  if type(setting_value) == "string" then
    local normalized = setting_value:lower()
    if normalized == "0" or normalized == "false" or normalized == "off" or normalized == "no" then
      return false
    end
    if normalized == "1" or normalized == "true" or normalized == "on" or normalized == "yes" then
      return true
    end
  end
  return default_value
end

local function split_path(path)
  local parts = {}
  for part in tostring(path or ""):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function tilde_path(path)
  local home = os.getenv("HOME")
  if type(path) ~= "string" or path == "" then
    return path
  end
  if type(home) == "string" and home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function split_bar(text)
  text = tostring(text or "")
  local start_pos, end_pos = text:find(BAR_SPLIT, 1, true)
  if not start_pos then
    return text, ""
  end
  return text:sub(1, start_pos - 1), text:sub(end_pos + 1)
end

function M.compose_bar(text, width)
  local left, right = split_bar(text)
  local total_width = math.max(1, tonumber(width) or 80)
  local left_width = tui_text.visible_width(left)
  local right_width = tui_text.visible_width(right)
  local gap = total_width - left_width - right_width - 1
  if right == "" then
    return left
  end
  if gap < 2 then
    gap = 2
  end
  return left .. string.rep(" ", gap) .. right
end

local function split_workspace(path)
  local parts = split_path(path)
  for index = 1, #parts - 1 do
    if parts[index] == ".worktrees" then
      return parts[index - 1], parts[index + 1]
    end
  end
  return nil, nil
end

-- Format a pi-ish status line. `arg_json` is a JSON object emitted by
-- the C TUI: {model=string, busy=bool, scroll=int}.
-- Returns a single string with fields separated by two spaces.
function M.status_line(arg_json)
  local arg = type(arg_json) == "table" and arg_json or prelude.safe_json_decode(arg_json, {})
  -- Prefer the runtime model override (set via psi.agent.set_model)
  -- over whatever C passed in, so a live `/model` swap or an
  -- extension-driven change is reflected in the footer without a
  -- restart. require() is resolved lazily to avoid a boot-time
  -- cycle (agent ↔ prompt ↔ tools ↔ tui).
  local ok, agent = pcall(require, "psi.agent_session")
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
  if ok and agent.pending_message_count then
    local queued = agent.pending_message_count()
    if queued > 0 then
      local preview = queue_preview_all(agent)
      if preview ~= "" then
        parts[#parts + 1] = "queue:" .. preview
      else
        parts[#parts + 1] = "queue:" .. tostring(queued)
      end
    end
  end
  if busy then
    parts[#parts + 1] = "busy…"
  end
  for _, hook in ipairs(status_hooks) do
    local ok_hook, extra = pcall(hook.fn, arg)
    if ok_hook and type(extra) == "string" and extra ~= "" then
      parts[#parts + 1] = extra
    end
  end
  return table.concat(parts, "  ")
end

function M.status_bar(arg_json)
  local arg = type(arg_json) == "table" and arg_json or prelude.safe_json_decode(arg_json, {})
  local ok, agent = pcall(require, "psi.agent_session")
  local resolved = ok and agent.model_descriptor(arg.model)
  local model = (resolved and resolved.id) or arg.model or "?"
  local left = pair("session", short_id(psi.session_id()), true)
  local right_parts = {
    pair("model", model, false),
    pair("messages", tostring(psi.session_message_count()), false),
  }
  for _, hook in ipairs(status_hooks) do
    local ok_hook, extra = pcall(hook.fn, arg)
    if ok_hook and type(extra) == "string" and extra ~= "" then
      right_parts[#right_parts + 1] = extra
    end
  end
  return left .. BAR_SPLIT .. table.concat(right_parts, sep())
end

-- Short help line for the footer. Content depends on mode.
function M.footer_hint(arg_json)
  local arg = type(arg_json) == "table" and arg_json or prelude.safe_json_decode(arg_json, {})
  if arg.busy then
    local busy_label = (type(arg.busy_label) == "string" and arg.busy_label ~= "")
        and arg.busy_label
      or "working"
    local dots = string.rep(".", math.max(1, tonumber(arg.busy_phase) or 1))
    return string.format(
      "%s (%s  • %s to interrupt) %s",
      busy_label,
      format_elapsed(arg.elapsed_seconds),
      keybindings.display("app.interrupt"),
      dots
    )
  end
  return ""
end

function M.workspace_line(cwd)
  local repo, worktree = split_workspace(cwd)
  if repo ~= nil and worktree ~= nil then
    return pair("repo", repo, false) .. sep() .. pair("worktree", worktree, true)
  end
  return pair("cwd", tilde_path(cwd or "-"), false)
end

function M.workspace_bar(cwd)
  local repo, worktree = split_workspace(cwd)
  if repo ~= nil and worktree ~= nil then
    return pair("repo", repo, false) .. BAR_SPLIT .. pair("worktree", worktree, true)
  end
  return pair("cwd", tilde_path(cwd or "-"), false) .. BAR_SPLIT .. ""
end

function M.render_busy_status(label_text, phase, elapsed_seconds, glisten_phase)
  local text = tostring(label_text or "working")
  local dots = ({ ".", "..", "..." })[((tonumber(phase) or 0) % 3) + 1]
  return shimmer_text(text, glisten_phase or phase)
    .. label(
      " ("
        .. format_elapsed(elapsed_seconds)
        .. "  • "
        .. keybindings.display("app.interrupt")
        .. " to interrupt)"
    )
    .. accent(" " .. dots)
end

function M.pick_busy_status()
  local labels = configured_busy_labels()
  seed_busy_rng()
  if labels == nil then
    return default_busy_label()
  end
  return labels[math.random(#labels)]
end

function M.show_thinking()
  return enabled_setting("tui.show_thinking", "PSI_SHOW_THINKING", false) and "1" or "0"
end

return M
