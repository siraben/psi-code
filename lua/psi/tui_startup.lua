-- Pi-style startup header for the interactive TUI.

local ansi = require("psi.ansi")
local keybindings = require("psi.keybindings")
local settings = require("psi.settings_manager")

local M = {}

local function bool_setting(path, fallback, default)
  local value = settings.get(path, nil)
  if value == nil and fallback ~= nil then
    value = settings.get(fallback, nil)
  end
  if value == nil then
    return default
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) == "string" then
    value = value:lower()
    if value == "true" or value == "1" or value == "yes" or value == "on" then
      return true
    end
    if value == "false" or value == "0" or value == "no" or value == "off" then
      return false
    end
  end
  return default
end

local function key_text(id)
  local text = keybindings.display(id)
  return text ~= "" and text or nil
end

local function raw_hint(key, description)
  if key == nil or key == "" then
    return nil
  end
  return ansi.dim(key) .. ansi.color("38;5;242", " " .. description)
end

local function hint(id, description)
  return raw_hint(key_text(id), description)
end

local function compact_hints()
  local clear = key_text("tui.input.clear")
  local exit = key_text("app.exit")
  local clear_exit = clear
  if clear and exit and clear ~= exit then
    clear_exit = clear .. "/" .. exit
  end
  local items = {
    hint("app.interrupt", "interrupt"),
    raw_hint(clear_exit, "clear/exit"),
    raw_hint("/", "commands"),
    raw_hint("!", "bash"),
    hint("app.tools.expand", "more"),
  }
  local out = {}
  for _, item in ipairs(items) do
    if item then
      out[#out + 1] = item
    end
  end
  return table.concat(out, ansi.color("38;5;242", " · "))
end

local function expanded_hints()
  local clear = key_text("tui.input.clear")
  local forward = key_text("app.model.cycleForward")
  local backward = key_text("app.model.cycleBackward")
  local model_cycle = forward
  if forward and backward and forward ~= backward then
    model_cycle = forward .. "/" .. backward
  end
  local items = {
    hint("app.interrupt", "to interrupt"),
    hint("tui.input.clear", "to clear"),
    raw_hint(clear and (clear .. " twice") or nil, "to exit"),
    hint("app.exit", "to exit (empty)"),
    hint("app.suspend", "to suspend"),
    hint("tui.editor.deleteToLineEnd", "to delete to end"),
    hint("app.thinking.cycle", "to cycle thinking level"),
    raw_hint(model_cycle, "to cycle models"),
    hint("app.model.select", "to select model"),
    hint("app.tools.expand", "to expand tools"),
    hint("app.thinking.toggle", "to expand thinking"),
    hint("app.editor.external", "for external editor"),
    hint("app.message.copy", "to copy the last response"),
    raw_hint("/", "for commands"),
    raw_hint("!", "to run shell commands"),
    raw_hint("!!", "to run shell commands (no context)"),
    hint("app.message.followUp", "to queue follow-up"),
    hint("tui.queue.restore", "to edit all queued messages"),
  }
  local out = {}
  for _, item in ipairs(items) do
    if item then
      out[#out + 1] = item
    end
  end
  return table.concat(out, "\n")
end

function M.visible()
  return not bool_setting("quietStartup", "tui.quiet_startup", false)
end

function M.render(opts)
  opts = type(opts) == "table" and opts or {}
  local expanded = not not opts.expanded
  local version = type(psi.version) == "function" and psi.version() or "?"
  local hints = expanded and expanded_hints() or compact_hints()
  local lines = {
    ansi.color("1;36", "psi") .. " " .. ansi.dim("v" .. tostring(version)),
    hints,
  }
  if not expanded then
    lines[#lines + 1] = ansi.dim(
      "Press " .. (key_text("app.tools.expand") or "Ctrl-O") .. " to show full startup help."
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ansi.dim(
    "psi can explain its own features and look up its docs. Ask it how to use or extend psi."
  )
  return table.concat(lines, "\n")
end

return M
