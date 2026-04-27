-- psi.tui: helpers for the C-side TUI to render things that depend
-- on Lua-owned state (session, context, usage). Kept tiny and
-- side-effect-free so the C layer can call them on every redraw.

local ansi = require("psi.ansi")
local context = require("psi.context")
local keybindings = require("psi.keybindings")
local prelude = require("psi.prelude")
local settings = require("psi.settings")

local M = {}
local BAR_SPLIT = string.char(31)
local busy_rng_seeded = false

local DEFAULT_BUSY_LABELS = {
  "gooning",
  "lowkirkuinely",
  "trolling",
  "rewriting in rust",
  "type error",
  "nix building",
  "hallucinating",
}

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

local function label(text)
  return ansi.color("2", tostring(text or ""))
end

local function value(text)
  return ansi.color("37", tostring(text or ""))
end

local function accent(text)
  return ansi.color("1;36", tostring(text or ""))
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
  local configured = settings.get("tui.busy_labels", settings.get("tui.working_words", nil))
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
  return DEFAULT_BUSY_LABELS
end

local function enabled_setting(path, env_name, default_value)
  local value = settings.get(path, nil)
  if value == nil and env_name ~= nil then
    value = os.getenv(env_name)
  end
  if value == nil then
    return default_value
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) == "string" then
    local normalized = value:lower()
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

local function visible_width(text)
  local width = 0
  local i = 1
  text = tostring(text or "")
  while i <= #text do
    local ch = text:byte(i)
    if ch == 27 and text:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #text and text:sub(j, j) ~= "m" do
        j = j + 1
      end
      i = j < #text and (j + 1) or (#text + 1)
    else
      if (ch & 0xC0) ~= 0x80 then
        width = width + 1
      end
      i = i + 1
    end
  end
  return width
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
  local left_width = visible_width(left)
  local right_width = visible_width(right)
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

function M.status_bar(arg_json)
  local arg = type(arg_json) == "table" and arg_json or prelude.safe_json_decode(arg_json, {})
  local ok, agent = pcall(require, "psi.agent")
  local resolved = ok and agent.model_descriptor(arg.model)
  local model = (resolved and resolved.id) or arg.model or "?"
  local left = pair("session", short_id(psi.session_id()), true)
  local right_parts = {
    pair("model", model, false),
    pair("messages", tostring(psi.session_message_count()), false),
  }
  for _, fn in ipairs(status_hooks) do
    local ok_hook, extra = pcall(fn)
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
    local label = (type(arg.busy_label) == "string" and arg.busy_label ~= "") and arg.busy_label or "Working"
    local dots = string.rep(".", math.max(1, tonumber(arg.busy_phase) or 1))
    return string.format(
      "%s (%s  • esc to interrupt) %s",
      label,
      format_elapsed(arg.elapsed_seconds),
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

function M.render_busy_status(label_text, phase, elapsed_seconds)
  local text = tostring(label_text or "working")
  local dots = ({ ".", "..", "..." })[((tonumber(phase) or 0) % 3) + 1]
  local chip = ansi.color("1;30;46", " working ")
  return chip .. accent(" " .. text)
    .. label(" (" .. format_elapsed(elapsed_seconds) .. "  • esc to interrupt)")
    .. accent(" " .. dots)
end

function M.pick_busy_status()
  local labels = configured_busy_labels()
  seed_busy_rng()
  return labels[math.random(#labels)]
end

function M.show_thinking()
  return enabled_setting("tui.show_thinking", "PSI_SHOW_THINKING", false) and "1" or "0"
end

return M
