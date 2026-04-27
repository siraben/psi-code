-- Built-in Vim-style TUI keybindings implemented as a Lua extension.

local M = {}

local function action(name, arg)
  return { action = name, arg = arg }
end

local function char(arg)
  return arg.key == "text" and arg.text or nil
end

local function is_mode(arg, mode)
  return (arg.editor_mode or "insert") == mode
end

local function visual_mode_arg(kind)
  return { mode = "visual", kind = kind }
end

local function normal_mode_arg()
  return { mode = "normal" }
end

local function insert_mode_arg()
  return { mode = "insert" }
end

local function handle_normal(arg)
  local c = char(arg)
  if arg.key == "escape" then
    return action("noop")
  end
  if arg.key == "ctrl-c" then
    return action("clear-buffer")
  end
  if arg.key == "ctrl-u" then
    return action("scroll", "page-up")
  end
  if arg.key == "ctrl-d" then
    return action("scroll", "page-down")
  end
  if arg.key == "ctrl-a" then
    return action("move-line-start")
  end
  if arg.key == "ctrl-e" then
    return action("move-line-end")
  end
  if c == "h" then
    return action("move-left")
  end
  if c == "l" then
    return action("move-right")
  end
  if c == "w" then
    return action("move-word-start-right")
  end
  if c == "b" then
    return action("move-word-left")
  end
  if c == "^" then
    return action("move-line-first-nonblank")
  end
  if c == "$" then
    return action("move-line-end")
  end
  if c == "j" then
    return action("move-line-down")
  end
  if c == "k" then
    return action("move-line-up")
  end
  if c == "G" then
    return action("scroll", "bottom")
  end
  if c == "g" then
    if arg.pending_key == "g" then
      return action("scroll", "top")
    end
    return action("vim-pending", "g")
  end
  if c == "i" then
    return action("vim-mode", insert_mode_arg())
  end
  if c == "a" then
    return action("vim-append")
  end
  if c == "A" then
    return action("vim-append-line")
  end
  if c == "I" then
    return action("vim-insert-line")
  end
  if c == "o" then
    return action("vim-open-line-below")
  end
  if c == "O" then
    return action("vim-open-line-above")
  end
  if c == "v" then
    return action("vim-mode", visual_mode_arg("char"))
  end
  if c == "V" then
    return action("vim-mode", visual_mode_arg("line"))
  end
  if arg.key == "ctrl-v" then
    return action("vim-mode", visual_mode_arg("block"))
  end
  if c == "p" then
    return action("vim-paste")
  end
  if c == "y" then
    return action("vim-yank")
  end
  return action("noop")
end

local function handle_visual(arg)
  local c = char(arg)
  if arg.key == "escape" then
    return action("vim-mode", normal_mode_arg())
  end
  if arg.key == "ctrl-c" then
    return action("clear-buffer")
  end
  if arg.key == "ctrl-u" then
    return action("scroll", "page-up")
  end
  if arg.key == "ctrl-d" then
    return action("scroll", "page-down")
  end
  if arg.key == "ctrl-a" then
    return action("move-line-start")
  end
  if arg.key == "ctrl-e" then
    return action("move-line-end")
  end
  if c == "h" then
    return action("move-left")
  end
  if c == "l" then
    return action("move-right")
  end
  if c == "w" then
    return action("move-word-start-right")
  end
  if c == "b" then
    return action("move-word-left")
  end
  if c == "^" then
    return action("move-line-first-nonblank")
  end
  if c == "$" then
    return action("move-line-end")
  end
  if c == "j" then
    return action("move-line-down")
  end
  if c == "k" then
    return action("move-line-up")
  end
  if c == "G" then
    return action("scroll", "bottom")
  end
  if c == "g" then
    if arg.pending_key == "g" then
      return action("scroll", "top")
    end
    return action("vim-pending", "g")
  end
  if c == "v" then
    return action("vim-mode", normal_mode_arg())
  end
  if c == "V" then
    return action("vim-mode", visual_mode_arg("line"))
  end
  if arg.key == "ctrl-v" then
    return action("vim-mode", visual_mode_arg("block"))
  end
  if arg.selection_kind == "block" and c == "I" then
    return action("vim-block-insert")
  end
  if arg.selection_kind == "block" and c == "A" then
    return action("vim-block-append")
  end
  if c == "y" then
    return action("vim-yank")
  end
  if c == "p" then
    return action("vim-paste")
  end
  return action("noop")
end

function M.install(psi)
  local tui = psi.tui or require("psi.tui")
  tui.register_key_handler(function(arg)
    arg = type(arg) == "table" and arg or {}
    if is_mode(arg, "insert") then
      if arg.key == "ctrl-c" then
        return action("clear-buffer")
      end
      if arg.key == "escape" then
        return action("vim-mode", normal_mode_arg())
      end
      return nil
    end
    if is_mode(arg, "visual") then
      return handle_visual(arg)
    end
    return handle_normal(arg)
  end)
  tui.register_status_hook(function(arg)
    local mode = type(arg) == "table" and arg.editor_mode or nil
    if mode == "normal" then
      return "mode:NORMAL"
    end
    if mode == "visual" then
      local kind = arg.selection_kind or "char"
      if kind == "line" then
        return "mode:VISUAL LINE"
      end
      if kind == "block" then
        return "mode:VISUAL BLOCK"
      end
      return "mode:VISUAL"
    end
    return "mode:INSERT"
  end)
  return true
end

return function(psi)
  return M.install(psi)
end
