-- Built-in Vim-style TUI keybindings implemented as a Lua extension.

local M = {}

local KEY_TEXT = "text"
local KEY_ESCAPE = "escape"
local KEY_CTRL_A = "ctrl-a"
local KEY_CTRL_C = "ctrl-c"
local KEY_CTRL_D = "ctrl-d"
local KEY_CTRL_E = "ctrl-e"
local KEY_CTRL_U = "ctrl-u"
local KEY_CTRL_V = "ctrl-v"

local MODE_INSERT = "insert"
local MODE_NORMAL = "normal"
local MODE_VISUAL = "visual"

local COMMAND_NAME = "vim"
local COMMAND_ARGUMENT_HINT = "[on|off|toggle]"
local COMMAND_DESCRIPTION = "Toggle TUI Vim modal editing"
local COMMAND_ACTION_KIND = "vim-toggle"
local CONFIG_ENABLED = "extensions.vim_keybindings.enabled"
local STARTUP_HOOK_NAME = "vim_keybindings"

local SELECTION_CHAR = "char"
local SELECTION_LINE = "line"
local SELECTION_BLOCK = "block"

local ACTION_CLEAR_BUFFER = "clear-buffer"
local ACTION_MOVE_LEFT = "move-left"
local ACTION_MOVE_LINE_DOWN = "move-line-down"
local ACTION_MOVE_LINE_END = "move-line-end"
local ACTION_MOVE_LINE_FIRST_NONBLANK = "move-line-first-nonblank"
local ACTION_MOVE_LINE_START = "move-line-start"
local ACTION_MOVE_LINE_UP = "move-line-up"
local ACTION_MOVE_RIGHT = "move-right"
local ACTION_MOVE_WORD_LEFT = "move-word-left"
local ACTION_MOVE_WORD_START_RIGHT = "move-word-start-right"
local ACTION_NOOP = "noop"
local ACTION_SCROLL = "scroll"
local ACTION_VIM_APPEND = "vim-append"
local ACTION_VIM_APPEND_LINE = "vim-append-line"
local ACTION_VIM_BLOCK_APPEND = "vim-block-append"
local ACTION_VIM_BLOCK_INSERT = "vim-block-insert"
local ACTION_VIM_INSERT_LINE = "vim-insert-line"
local ACTION_VIM_MODE = "vim-mode"
local ACTION_VIM_OPEN_LINE_ABOVE = "vim-open-line-above"
local ACTION_VIM_OPEN_LINE_BELOW = "vim-open-line-below"
local ACTION_VIM_PENDING = "vim-pending"
local ACTION_VIM_PASTE = "vim-paste"
local ACTION_VIM_YANK = "vim-yank"

local SCROLL_BOTTOM = "bottom"
local SCROLL_PAGE_DOWN = "page-down"
local SCROLL_PAGE_UP = "page-up"
local SCROLL_TOP = "top"

local CHAR_APPEND = "a"
local CHAR_APPEND_LINE = "A"
local CHAR_BLOCK_APPEND = "A"
local CHAR_BLOCK_INSERT = "I"
local CHAR_GOTO_BOTTOM = "G"
local CHAR_GOTO_PENDING = "g"
local CHAR_INSERT = "i"
local CHAR_INSERT_LINE = "I"
local CHAR_OPEN_LINE_ABOVE = "O"
local CHAR_OPEN_LINE_BELOW = "o"
local CHAR_PASTE = "p"
local CHAR_VISUAL = "v"
local CHAR_VISUAL_LINE = "V"
local CHAR_YANK = "y"

local STATUS_BY_MODE = {
  [MODE_INSERT] = "mode:INSERT",
  [MODE_NORMAL] = "mode:NORMAL",
}

local STATUS_BY_SELECTION = {
  [SELECTION_CHAR] = "mode:VISUAL",
  [SELECTION_LINE] = "mode:VISUAL LINE",
  [SELECTION_BLOCK] = "mode:VISUAL BLOCK",
}

local key_handler_id = nil
local status_hook_id = nil

local function records()
  return require("psi.records")
end

local function settings()
  return require("psi.settings")
end

local function keybindings()
  return require("psi.keybindings")
end

local function action(name, arg)
  return { action = name, arg = arg }
end

local function binding(name, arg)
  return { name = name, arg = arg }
end

local function char(arg)
  return arg.key == KEY_TEXT and arg.text or nil
end

local function is_mode(arg, mode)
  return (arg.editor_mode or MODE_INSERT) == mode
end

local function visual_mode_arg(kind)
  return { mode = MODE_VISUAL, kind = kind }
end

local function normal_mode_arg()
  return { mode = MODE_NORMAL }
end

local function insert_mode_arg()
  return { mode = MODE_INSERT }
end

local function resolve_arg(arg)
  if type(arg) == "function" then
    return arg()
  end
  return arg
end

local function resolve_binding(spec, arg)
  if spec == nil then
    return nil
  end
  if type(spec) == "function" then
    return spec(arg)
  end
  return action(spec.name, resolve_arg(spec.arg))
end

local function pending_g_action(arg)
  if arg.pending_key == CHAR_GOTO_PENDING then
    return action(ACTION_SCROLL, SCROLL_TOP)
  end
  return action(ACTION_VIM_PENDING, CHAR_GOTO_PENDING)
end

local NORMAL_KEY_BINDINGS = {
  [KEY_ESCAPE] = binding(ACTION_NOOP),
  [KEY_CTRL_C] = binding(ACTION_CLEAR_BUFFER),
  [KEY_CTRL_U] = binding(ACTION_SCROLL, SCROLL_PAGE_UP),
  [KEY_CTRL_D] = binding(ACTION_SCROLL, SCROLL_PAGE_DOWN),
  [KEY_CTRL_A] = binding(ACTION_MOVE_LINE_START),
  [KEY_CTRL_E] = binding(ACTION_MOVE_LINE_END),
  [KEY_CTRL_V] = binding(ACTION_VIM_MODE, function()
    return visual_mode_arg(SELECTION_BLOCK)
  end),
}

local NORMAL_CHAR_BINDINGS = {
  h = binding(ACTION_MOVE_LEFT),
  l = binding(ACTION_MOVE_RIGHT),
  w = binding(ACTION_MOVE_WORD_START_RIGHT),
  b = binding(ACTION_MOVE_WORD_LEFT),
  ["^"] = binding(ACTION_MOVE_LINE_FIRST_NONBLANK),
  ["$"] = binding(ACTION_MOVE_LINE_END),
  j = binding(ACTION_MOVE_LINE_DOWN),
  k = binding(ACTION_MOVE_LINE_UP),
  [CHAR_GOTO_BOTTOM] = binding(ACTION_SCROLL, SCROLL_BOTTOM),
  [CHAR_GOTO_PENDING] = pending_g_action,
  [CHAR_INSERT] = binding(ACTION_VIM_MODE, insert_mode_arg),
  [CHAR_APPEND] = binding(ACTION_VIM_APPEND),
  [CHAR_APPEND_LINE] = binding(ACTION_VIM_APPEND_LINE),
  [CHAR_INSERT_LINE] = binding(ACTION_VIM_INSERT_LINE),
  [CHAR_OPEN_LINE_BELOW] = binding(ACTION_VIM_OPEN_LINE_BELOW),
  [CHAR_OPEN_LINE_ABOVE] = binding(ACTION_VIM_OPEN_LINE_ABOVE),
  [CHAR_VISUAL] = binding(ACTION_VIM_MODE, function()
    return visual_mode_arg(SELECTION_CHAR)
  end),
  [CHAR_VISUAL_LINE] = binding(ACTION_VIM_MODE, function()
    return visual_mode_arg(SELECTION_LINE)
  end),
  [CHAR_PASTE] = binding(ACTION_VIM_PASTE),
  [CHAR_YANK] = binding(ACTION_VIM_YANK),
}

local VISUAL_KEY_BINDINGS = {
  [KEY_ESCAPE] = binding(ACTION_VIM_MODE, normal_mode_arg),
  [KEY_CTRL_C] = binding(ACTION_CLEAR_BUFFER),
  [KEY_CTRL_U] = binding(ACTION_SCROLL, SCROLL_PAGE_UP),
  [KEY_CTRL_D] = binding(ACTION_SCROLL, SCROLL_PAGE_DOWN),
  [KEY_CTRL_A] = binding(ACTION_MOVE_LINE_START),
  [KEY_CTRL_E] = binding(ACTION_MOVE_LINE_END),
  [KEY_CTRL_V] = binding(ACTION_VIM_MODE, function()
    return visual_mode_arg(SELECTION_BLOCK)
  end),
}

local VISUAL_CHAR_BINDINGS = {
  h = binding(ACTION_MOVE_LEFT),
  l = binding(ACTION_MOVE_RIGHT),
  w = binding(ACTION_MOVE_WORD_START_RIGHT),
  b = binding(ACTION_MOVE_WORD_LEFT),
  ["^"] = binding(ACTION_MOVE_LINE_FIRST_NONBLANK),
  ["$"] = binding(ACTION_MOVE_LINE_END),
  j = binding(ACTION_MOVE_LINE_DOWN),
  k = binding(ACTION_MOVE_LINE_UP),
  [CHAR_GOTO_BOTTOM] = binding(ACTION_SCROLL, SCROLL_BOTTOM),
  [CHAR_GOTO_PENDING] = pending_g_action,
  [CHAR_VISUAL] = binding(ACTION_VIM_MODE, normal_mode_arg),
  [CHAR_VISUAL_LINE] = binding(ACTION_VIM_MODE, function()
    return visual_mode_arg(SELECTION_LINE)
  end),
  [CHAR_PASTE] = binding(ACTION_VIM_PASTE),
  [CHAR_YANK] = binding(ACTION_VIM_YANK),
}

local VISUAL_BLOCK_CHAR_BINDINGS = {
  [CHAR_BLOCK_INSERT] = binding(ACTION_VIM_BLOCK_INSERT),
  [CHAR_BLOCK_APPEND] = binding(ACTION_VIM_BLOCK_APPEND),
}

local INSERT_KEY_BINDINGS = {
  [KEY_CTRL_C] = binding(ACTION_CLEAR_BUFFER),
  [KEY_ESCAPE] = binding(ACTION_VIM_MODE, normal_mode_arg),
}

local function dispatch(bindings, key, arg)
  return resolve_binding(bindings[key], arg)
end

local function handle_normal(arg)
  return dispatch(NORMAL_KEY_BINDINGS, arg.key, arg)
    or dispatch(NORMAL_CHAR_BINDINGS, char(arg), arg)
    or action(ACTION_NOOP)
end

local function handle_visual(arg)
  local c = char(arg)
  return dispatch(VISUAL_KEY_BINDINGS, arg.key, arg)
    or (arg.selection_kind == SELECTION_BLOCK and dispatch(VISUAL_BLOCK_CHAR_BINDINGS, c, arg))
    or dispatch(VISUAL_CHAR_BINDINGS, c, arg)
    or action(ACTION_NOOP)
end

local function key_handler(arg)
  arg = type(arg) == "table" and arg or {}
  if arg.busy and keybindings().matches(arg.key, "app.interrupt") then
    return nil
  end
  if is_mode(arg, MODE_INSERT) then
    return dispatch(INSERT_KEY_BINDINGS, arg.key, arg)
  end
  if is_mode(arg, MODE_VISUAL) then
    return handle_visual(arg)
  end
  return handle_normal(arg)
end

local function status_hook(arg)
  local mode = type(arg) == "table" and arg.editor_mode or nil
  if mode == MODE_VISUAL then
    return STATUS_BY_SELECTION[arg.selection_kind or SELECTION_CHAR]
  end
  return STATUS_BY_MODE[mode] or STATUS_BY_MODE[MODE_INSERT]
end

function M.is_enabled()
  return key_handler_id ~= nil
end

function M.enable(psi)
  if M.is_enabled() then
    return true
  end
  local tui = psi.tui or require("psi.tui")
  key_handler_id = tui.register_key_handler(key_handler)
  status_hook_id = tui.register_status_hook(status_hook)
  return true
end

function M.disable(psi)
  if not M.is_enabled() then
    return true
  end
  local tui = psi.tui or require("psi.tui")
  if tui.unregister_key_handler then
    tui.unregister_key_handler(key_handler_id)
  end
  if tui.unregister_status_hook then
    tui.unregister_status_hook(status_hook_id)
  end
  key_handler_id = nil
  status_hook_id = nil
  return true
end

function M.set_enabled(psi, enabled)
  if enabled then
    return M.enable(psi)
  end
  return M.disable(psi)
end

function M.toggle(psi, value)
  if value == "on" or value == true then
    M.enable(psi)
  elseif value == "off" or value == false then
    M.disable(psi)
  else
    if M.is_enabled() then
      M.disable(psi)
    else
      M.enable(psi)
    end
  end
  return M.is_enabled()
end

M.install = M.enable

local function command_handler(rest)
  rest = tostring(rest or ""):match("^%s*(.-)%s*$")
  return records().new_command_action(COMMAND_ACTION_KIND, rest ~= "" and rest or "toggle")
end

function M.register(psi)
  local commands = psi.commands or require("psi.commands")
  local tui = psi.tui or require("psi.tui")

  commands.register(COMMAND_NAME, {
    handler = command_handler,
    description = COMMAND_DESCRIPTION,
    argument_hint = COMMAND_ARGUMENT_HINT,
  })

  tui.register_command_action_handler(COMMAND_ACTION_KIND, function(payload, context)
    local enabled = M.toggle(psi, payload)
    if context and context.reset_editor then
      context.reset_editor()
    end
    if context and context.set_status then
      context.set_status(enabled and "Vim keybindings enabled" or "Vim keybindings disabled", false)
    end
    return true
  end)

  tui.register_startup_hook(STARTUP_HOOK_NAME, function()
    M.set_enabled(psi, settings().get(CONFIG_ENABLED, false) == true)
  end)

  return true
end

return M
