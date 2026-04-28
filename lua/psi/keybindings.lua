-- psi.keybindings: canonical keybinding metadata and display helpers.
--
-- C normalizes terminal input into small key ids ("enter", "ctrl-d",
-- "page-up", ...). This module owns the action-to-key mapping, optional
-- user overrides, and the help text rendered by /hotkeys and the TUI footer.

local prelude = require("psi.prelude")

local M = {}

local DEFINITIONS = {
  {
    id = "tui.input.submit",
    section = "Editing",
    default_keys = { "enter" },
    description = "Send message",
  },
  {
    id = "tui.input.newLine",
    section = "Editing",
    default_keys = { "shift-enter" },
    description = "Insert newline",
  },
  {
    id = "tui.input.clear",
    section = "Editing",
    default_keys = {},
    description = "Delete to start of prompt",
  },
  {
    id = "tui.editor.cursorLeft",
    section = "Navigation",
    default_keys = { "left", "ctrl-b" },
    description = "Move cursor left",
  },
  {
    id = "tui.editor.cursorRight",
    section = "Navigation",
    default_keys = { "right", "ctrl-f" },
    description = "Move cursor right",
  },
  {
    id = "tui.editor.cursorWordLeft",
    section = "Navigation",
    default_keys = { "alt-b" },
    description = "Move cursor word left",
  },
  {
    id = "tui.editor.cursorWordRight",
    section = "Navigation",
    default_keys = { "alt-f" },
    description = "Move cursor word right",
  },
  {
    id = "tui.editor.cursorLineStart",
    section = "Navigation",
    default_keys = { "home", "ctrl-a" },
    description = "Move to line start",
  },
  {
    id = "tui.editor.cursorLineEnd",
    section = "Navigation",
    default_keys = { "end", "ctrl-e" },
    description = "Move to line end",
  },
  {
    id = "tui.transcript.lineUp",
    section = "Navigation",
    default_keys = { "up" },
    description = "Scroll transcript up",
  },
  {
    id = "tui.transcript.lineDown",
    section = "Navigation",
    default_keys = { "down" },
    description = "Scroll transcript down",
  },
  {
    id = "tui.transcript.pageUp",
    section = "Navigation",
    default_keys = { "page-up", "ctrl-u" },
    description = "Scroll transcript page up",
  },
  {
    id = "tui.transcript.pageDown",
    section = "Navigation",
    default_keys = { "page-down" },
    description = "Scroll transcript page down",
  },
  {
    id = "tui.queue.previous",
    section = "Navigation",
    default_keys = { "ctrl-p" },
    description = "Show previous queued message",
  },
  {
    id = "tui.queue.next",
    section = "Navigation",
    default_keys = { "ctrl-n" },
    description = "Show next queued message",
  },
  {
    id = "tui.queue.restore",
    section = "Navigation",
    default_keys = { "up" },
    description = "Edit queued message",
  },
  {
    id = "tui.editor.deleteCharBackward",
    section = "Editing",
    default_keys = { "backspace" },
    description = "Delete character backward",
  },
  {
    id = "tui.editor.deleteCharForward",
    section = "Editing",
    default_keys = { "delete" },
    description = "Delete character forward",
  },
  {
    id = "tui.editor.deleteWordBackward",
    section = "Editing",
    default_keys = { "ctrl-w", "alt-backspace" },
    description = "Delete word backward",
  },
  {
    id = "tui.editor.deleteWordForward",
    section = "Editing",
    default_keys = { "alt-d" },
    description = "Delete word forward",
  },
  {
    id = "tui.editor.deleteToLineEnd",
    section = "Editing",
    default_keys = { "ctrl-k" },
    description = "Delete to end of prompt",
  },
  {
    id = "app.interrupt",
    section = "Other",
    default_keys = { "ctrl-g" },
    description = "Abort current turn",
  },
  {
    id = "app.exit",
    section = "Other",
    default_keys = { "ctrl-d" },
    description = "Exit when prompt is empty",
  },
  {
    id = "app.redraw",
    section = "Other",
    default_keys = { "ctrl-l" },
    description = "Redraw screen",
  },
  {
    id = "app.suspend",
    section = "Other",
    default_keys = { "ctrl-z" },
    description = "Suspend to background",
  },
}

local SECTION_ORDER = { "Navigation", "Editing", "Other" }

local by_id = {}
for _, def in ipairs(DEFINITIONS) do
  by_id[def.id] = def
end

local function key_list(value)
  if value == nil then
    return nil
  end
  if type(value) == "string" then
    return { value }
  end
  if type(value) ~= "table" then
    return nil
  end
  local out = {}
  for _, key in ipairs(value) do
    if type(key) == "string" then
      out[#out + 1] = key
    end
  end
  return out
end

local function normalize_key(key)
  key = tostring(key or "")
  key = key:gsub("_", "-")
  if key == "pageUp" or key == "pageup" or key == "pgup" then
    return "page-up"
  end
  if key == "pageDown" or key == "pagedown" or key == "pgdn" then
    return "page-down"
  end
  if key == "ctrlUp" or key == "ctrlup" then
    return "ctrl-up"
  end
  if key == "ctrlDown" or key == "ctrldown" then
    return "ctrl-down"
  end
  if key == "altUp" or key == "altup" then
    return "alt-up"
  end
  if key == "altDown" or key == "altdown" then
    return "alt-down"
  end
  return key
end

local function normalize_keys(keys)
  local seen = {}
  local out = {}
  for _, key in ipairs(keys or {}) do
    key = normalize_key(key)
    if key ~= "" and not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  return out
end

local overrides = nil
local resolved = nil
local conflicts = nil

local function merge(dst, src)
  for id, keys in pairs(src or {}) do
    if by_id[id] then
      local parsed = key_list(keys)
      if parsed then
        dst[id] = parsed
      end
    end
  end
  return dst
end

local function read_json(path)
  if not (path and psi.file_exists(path)) then
    return nil
  end
  local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
  if type(parsed) == "table" then
    return parsed
  end
  return nil
end

local function load_overrides()
  local out = {}
  local home = os.getenv("HOME")
  if home and home ~= "" then
    merge(out, read_json(prelude.path_join(home, ".config/psi/keybindings.json")))
  end
  merge(out, read_json(".psi/keybindings.json"))
  return out
end

local function ensure_resolved()
  if resolved then
    return resolved
  end
  overrides = overrides or load_overrides()
  resolved = {}
  conflicts = {}

  local user_claims = {}
  for id, keys in pairs(overrides) do
    for _, key in ipairs(normalize_keys(keys)) do
      user_claims[key] = user_claims[key] or {}
      user_claims[key][#user_claims[key] + 1] = id
    end
  end
  for key, ids in pairs(user_claims) do
    if #ids > 1 then
      table.sort(ids)
      conflicts[#conflicts + 1] = { key = key, keybindings = ids }
    end
  end
  table.sort(conflicts, function(a, b)
    return a.key < b.key
  end)

  for _, def in ipairs(DEFINITIONS) do
    local keys = overrides[def.id] or def.default_keys
    resolved[def.id] = normalize_keys(keys)
  end
  return resolved
end

function M.reload()
  overrides = load_overrides()
  resolved = nil
  conflicts = nil
  return ensure_resolved()
end

function M.definitions()
  local out = {}
  for i, def in ipairs(DEFINITIONS) do
    out[i] = def
  end
  return out
end

function M.keys(id)
  local keys = ensure_resolved()[id] or {}
  local out = {}
  for i, key in ipairs(keys) do
    out[i] = key
  end
  return out
end

function M.resolved()
  local out = {}
  for id, keys in pairs(ensure_resolved()) do
    out[id] = {}
    for i, key in ipairs(keys) do
      out[id][i] = key
    end
  end
  return out
end

function M.conflicts()
  ensure_resolved()
  local out = {}
  for i, conflict in ipairs(conflicts or {}) do
    local ids = {}
    for j, id in ipairs(conflict.keybindings or {}) do
      ids[j] = id
    end
    out[i] = { key = conflict.key, keybindings = ids }
  end
  return out
end

function M.matches(key, id)
  key = normalize_key(key)
  for _, candidate in ipairs(M.keys(id)) do
    if candidate == key then
      return true
    end
  end
  return false
end

local DISPLAY = {
  ["alt-b"] = "Alt-B",
  ["alt-f"] = "Alt-F",
  ["alt-d"] = "Alt-D",
  ["alt-up"] = "Alt-Up",
  ["alt-backspace"] = "Alt-Backspace",
  ["backspace"] = "Backspace",
  ["ctrl-a"] = "Ctrl-A",
  ["ctrl-b"] = "Ctrl-B",
  ["ctrl-d"] = "Ctrl-D",
  ["ctrl-e"] = "Ctrl-E",
  ["ctrl-f"] = "Ctrl-F",
  ["ctrl-g"] = "Ctrl-G",
  ["ctrl-k"] = "Ctrl-K",
  ["ctrl-l"] = "Ctrl-L",
  ["ctrl-n"] = "Ctrl-N",
  ["ctrl-p"] = "Ctrl-P",
  ["ctrl-up"] = "Ctrl-Up",
  ["ctrl-u"] = "Ctrl-U",
  ["ctrl-v"] = "Ctrl-V",
  ["ctrl-w"] = "Ctrl-W",
  ["ctrl-z"] = "Ctrl-Z",
  ["delete"] = "Delete",
  ["down"] = "Down",
  ["end"] = "End",
  ["enter"] = "Enter",
  ["escape"] = "Esc",
  ["home"] = "Home",
  ["left"] = "Left",
  ["page-down"] = "PgDn",
  ["page-up"] = "PgUp",
  ["right"] = "Right",
  ["shift-enter"] = "Shift-Enter",
  ["up"] = "Up",
}

function M.key_display(key)
  return DISPLAY[normalize_key(key)] or tostring(key)
end

function M.display(id)
  local pieces = {}
  for _, key in ipairs(M.keys(id)) do
    pieces[#pieces + 1] = M.key_display(key)
  end
  return table.concat(pieces, " / ")
end

function M.hotkeys_text()
  local lines = { "keyboard shortcuts\n" }
  for _, section in ipairs(SECTION_ORDER) do
    lines[#lines + 1] = "\n" .. section:lower() .. ":\n"
    for _, def in ipairs(DEFINITIONS) do
      if def.section == section then
        local keys = M.display(def.id)
        if keys ~= "" then
          lines[#lines + 1] = string.format("  %-24s %s\n", keys, def.description)
        end
      end
    end
  end
  lines[#lines + 1] = "\ncommands:\n"
  lines[#lines + 1] = "  /                        Slash commands\n"
  lines[#lines + 1] = "  !                        Run shell command\n"
  lines[#lines + 1] = "  !!                       Run shell command (excluded from context)"
  return table.concat(lines)
end

function M.footer_hint(arg_json)
  local arg = type(arg_json) == "table" and arg_json or prelude.safe_json_decode(arg_json, {})
  if arg.busy then
    return table.concat({
      M.display("tui.input.submit") .. " queue",
      M.display("tui.queue.previous") .. "/" .. M.display("tui.queue.next") .. " queued",
      M.display("tui.queue.restore") .. " edit",
      M.display("app.interrupt") .. " abort",
      "/queue",
      "/btw",
    }, "  ")
  end
  local submit = M.display("tui.input.submit")
  local newline = M.display("tui.input.newLine")
  if (tonumber(arg.scroll) or 0) > 0 then
    return table.concat({
      M.display("tui.transcript.lineUp")
        .. "/"
        .. M.display("tui.transcript.lineDown")
        .. " scroll",
      M.display("tui.transcript.pageUp") .. "/" .. M.display("tui.transcript.pageDown") .. " page",
      submit .. "=submit",
      newline .. "=newline",
      "/help",
      "/quit",
    }, "  ")
  end
  return table.concat({
    submit .. " submit",
    newline .. " newline",
    M.display("tui.transcript.lineUp") .. "/" .. M.display("tui.transcript.lineDown") .. " scroll",
    "/help",
    "/quit",
  }, "  ")
end

return M
