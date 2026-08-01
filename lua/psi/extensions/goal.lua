-- Session-scoped /goal extension.
--
-- Goals are durable custom entries, not transcript messages. The active
-- objective is added to the system prompt and shown in the TUI status bar,
-- while the core agent/session machinery remains unaware of planning state.

local M = {}

local ENTRY_NAME = "psi.goal"
local STATUS_ACTIVE = "active"
local STATUS_CLEARED = "cleared"
local STATUS_COMPLETED = "completed"

local cached_key = nil
local cached_state = nil
local compaction_goal = nil
local status_hook_id = nil
local sync_status_hook

local function trim(psi, value)
  return psi.prelude.trim(tostring(value or ""))
end

local function state_key(psi)
  local session = psi.session
  return table.concat({
    tostring(psi.session_id() or ""),
    tostring(psi.session_path() or ""),
    tostring(session.count()),
    tostring(session.last_entry_id() or ""),
  }, "\0")
end

local function read_state(psi)
  local key = state_key(psi)
  if key == cached_key then
    return cached_state
  end

  local latest = nil
  for _, message in ipairs(psi.session.messages()) do
    local body = psi.prelude.safe_json_decode(message.data, nil)
    if
      type(body) == "table"
      and body.__entry_type == "custom"
      and body.name == ENTRY_NAME
      and type(body.data) == "table"
    then
      latest = body.data
    end
  end

  cached_key = key
  cached_state = latest
  return latest
end

local function active_goal(psi)
  local state = read_state(psi)
  if
    type(state) == "table"
    and state.status == STATUS_ACTIVE
    and type(state.objective) == "string"
    and trim(psi, state.objective) ~= ""
  then
    return state
  end
  return nil
end

local function append_state(psi, objective, status)
  psi.session.append_custom(ENTRY_NAME, {
    objective = objective or "",
    status = status,
  })
  cached_key = nil

  local path = psi.session.ensure_default_path()
  local ok, err = psi.session.save(path)
  sync_status_hook(psi)
  if not ok then
    return false, err
  end
  return true
end

local function print_action(psi, text)
  return psi.records.new_command_action("print", text)
end

local function usage(psi)
  return print_action(psi, "usage: /goal [show|set <objective>|complete|clear]")
end

local function command_handler(psi, rest)
  rest = trim(psi, rest)
  local verb, tail = rest:match("^(%S+)%s*(.-)%s*$")
  verb = verb and verb:lower() or "show"

  if rest == "" or verb == "show" or verb == "status" then
    if tail and tail ~= "" then
      return usage(psi)
    end
    local state = read_state(psi)
    if type(state) ~= "table" or trim(psi, state.objective) == "" then
      return print_action(psi, "no goal set")
    end
    return print_action(
      psi,
      string.format("goal (%s): %s", tostring(state.status or STATUS_ACTIVE), state.objective)
    )
  end

  if verb == "clear" then
    if tail ~= "" then
      return usage(psi)
    end
    local ok, err = append_state(psi, "", STATUS_CLEARED)
    return print_action(
      psi,
      ok and "goal cleared" or ("goal cleared in memory; save failed: " .. tostring(err))
    )
  end

  if verb == "complete" or verb == "done" then
    if tail ~= "" then
      return usage(psi)
    end
    local current = active_goal(psi)
    if not current then
      return print_action(psi, "no active goal")
    end
    local ok, err = append_state(psi, current.objective, STATUS_COMPLETED)
    local message = "goal completed: " .. current.objective
    if not ok then
      message = message .. " (save failed: " .. tostring(err) .. ")"
    end
    return print_action(psi, message)
  end

  local objective = rest
  if verb == "set" then
    objective = trim(psi, tail)
  end
  if objective == "" then
    return usage(psi)
  end

  local ok, err = append_state(psi, objective, STATUS_ACTIVE)
  local message = "goal set: " .. objective
  if not ok then
    message = message .. " (save failed: " .. tostring(err) .. ")"
  end
  return print_action(psi, message)
end

local function status_text(psi)
  local state = active_goal(psi)
  if not state then
    return nil
  end
  local objective = state.objective:gsub("%s+", " ")
  local text = require("psi.tui_text")
  local shortened = text.truncate_columns(objective, 36)
  if text.visible_width(shortened) < text.visible_width(objective) then
    shortened = text.truncate_columns(objective, 35) .. "…"
  end
  return "goal:" .. shortened
end

sync_status_hook = function(psi)
  local active = active_goal(psi) ~= nil
  if active and status_hook_id == nil then
    status_hook_id = psi.tui.register_status_hook(function()
      return status_text(psi)
    end)
  elseif not active and status_hook_id ~= nil then
    psi.tui.unregister_status_hook(status_hook_id)
    status_hook_id = nil
  end
end

local function transform_prompt(psi, prompt)
  local state = active_goal(psi)
  sync_status_hook(psi)
  if not state then
    return nil
  end
  return table.concat({
    prompt,
    "\n\n<active_goal>\n",
    state.objective,
    "\n</active_goal>\n",
    "Treat this as the user's persistent objective. Keep making progress toward it across turns until the user completes or clears it.",
  })
end

function M.register(psi)
  if status_hook_id ~= nil then
    psi.tui.unregister_status_hook(status_hook_id)
    status_hook_id = nil
  end
  psi.commands.register("goal", {
    description = "Set or inspect the persistent session goal",
    argument_hint = "[show|set <objective>|complete|clear]",
    handler = function(rest)
      return command_handler(psi, rest)
    end,
  })

  psi.prompt.register_transformer(function(prompt)
    return transform_prompt(psi, prompt)
  end)

  psi.events.on("session-start", function()
    cached_key = nil
    sync_status_hook(psi)
  end)

  psi.events.on("compaction-start", function()
    compaction_goal = active_goal(psi)
  end)
  psi.events.on("compaction-end", function()
    if compaction_goal then
      psi.session.append_custom(ENTRY_NAME, {
        objective = compaction_goal.objective,
        status = STATUS_ACTIVE,
      })
      cached_key = nil
    end
    compaction_goal = nil
    sync_status_hook(psi)
  end)

  sync_status_hook(psi)

  return true
end

M.install = M.register
M._read_state = read_state

return M
