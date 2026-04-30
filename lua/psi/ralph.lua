-- psi.ralph: explicit lifecycle state for /ralph persistence loops.
--
-- Ralph is intentionally state-driven. The assistant may continue ordinary
-- conversation, but the loop only stops when this module records a terminal
-- state through the ralph_state tool or a local cancel path.

local prelude = require("psi.prelude")
local session = require("psi.session")

local M = {}

local ACTIVE_PHASES = {
  starting = true,
  executing = true,
  verifying = true,
  fixing = true,
}

local TERMINAL_PHASES = {
  complete = true,
  failed = true,
  cancelled = true,
}

local DEFAULT_MAX_ITERATIONS = 10

local function now()
  return prelude.iso_timestamp()
end

local function current_session_id()
  session.ensure_id()
  return psi.session_id() or ""
end

local function path_safe_id(id)
  id = tostring(id or "")
  id = id:gsub("[^A-Za-z0-9_.-]", "_")
  if id == "" then
    return "unknown"
  end
  return id
end

local function state_path()
  return prelude.path_join(
    prelude.path_join(prelude.path_join(psi.cwd() or ".", ".psi"), "ralph"),
    path_safe_id(current_session_id()) .. ".json"
  )
end

function M.state_path()
  return state_path()
end

local function owns_state(state)
  return type(state) == "table"
    and type(state.session_id) == "string"
    and state.session_id ~= ""
    and state.session_id == current_session_id()
end

function M.owns_state(state)
  return owns_state(state)
end

local function normalize_phase(phase)
  if type(phase) ~= "string" then
    return nil
  end
  phase = prelude.trim(phase):lower()
  if phase == "start" or phase == "started" then
    return "starting"
  end
  if phase == "execute" or phase == "execution" then
    return "executing"
  end
  if phase == "verify" or phase == "verification" then
    return "verifying"
  end
  if phase == "fix" then
    return "fixing"
  end
  if phase == "completed" then
    return "complete"
  end
  if phase == "fail" or phase == "blocked" then
    return "failed"
  end
  if phase == "cancel" then
    return "cancelled"
  end
  if ACTIVE_PHASES[phase] or TERMINAL_PHASES[phase] then
    return phase
  end
  return nil
end

function M.normalize_phase(phase)
  return normalize_phase(phase)
end

local function valid_state(raw)
  if type(raw) ~= "table" then
    return nil
  end
  if raw.mode ~= nil and raw.mode ~= "ralph" then
    return nil
  end
  local phase = normalize_phase(raw.current_phase or raw.phase)
  if not phase then
    phase = raw.active == false and "cancelled" or "starting"
  end
  raw.mode = "ralph"
  raw.current_phase = phase
  raw.active = raw.active == true and not TERMINAL_PHASES[phase]
  raw.iteration = tonumber(raw.iteration) or 0
  raw.max_iterations = tonumber(raw.max_iterations) or DEFAULT_MAX_ITERATIONS
  if raw.max_iterations < 1 then
    raw.max_iterations = DEFAULT_MAX_ITERATIONS
  end
  return raw
end

function M.read()
  local path = state_path()
  if not psi.file_exists(path) then
    return nil
  end
  return valid_state(prelude.safe_json_decode(psi.read_file(path), nil))
end

function M.write(state)
  state = valid_state(state)
  if not state then
    return false, "invalid ralph state"
  end
  state.session_id = state.session_id or current_session_id()
  if not owns_state(state) then
    return false, "ralph belongs to another session"
  end
  state.updated_at = now()
  local path = state_path()
  if not psi.mkdir_parent(path) then
    return false, "could not create .psi directory"
  end
  local ok = psi.file_write(path, psi.json_encode(state))
  if not ok then
    return false, "could not write ralph state"
  end
  return true, state
end

function M.is_active(state)
  state = state or M.read()
  return type(state) == "table"
    and owns_state(state)
    and state.active == true
    and ACTIVE_PHASES[state.current_phase] == true
end

local function evidence_list(state)
  if type(state.evidence) == "table" then
    return state.evidence
  end
  state.evidence = {}
  return state.evidence
end

function M.update(fields)
  local state = M.read()
  if not state then
    return false, "ralph is not active"
  end
  if not M.is_active(state) then
    return false, "ralph is not active"
  end
  fields = fields or {}
  local phase = normalize_phase(fields.current_phase or fields.phase)
  if phase then
    state.current_phase = phase
    state.active = not TERMINAL_PHASES[phase]
  end
  if type(fields.evidence) == "string" and fields.evidence ~= "" then
    local items = evidence_list(state)
    items[#items + 1] = {
      at = now(),
      text = fields.evidence,
    }
  end
  if type(fields.stop_reason) == "string" and fields.stop_reason ~= "" then
    state.stop_reason = fields.stop_reason
  end
  if TERMINAL_PHASES[state.current_phase] then
    state.active = false
    state.completed_at = state.completed_at or now()
  end
  return M.write(state)
end

function M.start(task, opts)
  task = prelude.trim(task or "")
  if task == "" then
    return nil, "missing task"
  end
  opts = opts or {}
  local state = {
    active = true,
    mode = "ralph",
    iteration = 0,
    max_iterations = tonumber(opts.max_iterations) or DEFAULT_MAX_ITERATIONS,
    current_phase = "starting",
    task_description = task,
    started_at = now(),
    session_id = current_session_id(),
    evidence = {},
  }
  local ok, written = M.write(state)
  if not ok then
    return nil, written
  end
  return written
end

function M.stop(reason, phase)
  local state = M.read()
  if not state then
    return false, "ralph is not active"
  end
  if not owns_state(state) then
    return false, "ralph belongs to another session"
  end
  state.active = false
  state.current_phase = normalize_phase(phase) or "cancelled"
  if not TERMINAL_PHASES[state.current_phase] then
    state.current_phase = "cancelled"
  end
  state.stop_reason = reason or state.stop_reason or "cancelled"
  state.completed_at = now()
  return M.write(state)
end

local function compact_state_json(state)
  return psi.json_encode({
    active = state.active,
    iteration = state.iteration,
    max_iterations = state.max_iterations,
    current_phase = state.current_phase,
    task_description = state.task_description,
    stop_reason = state.stop_reason,
    evidence = state.evidence,
  })
end

function M.start_prompt(task, opts)
  local state, err = M.start(task, opts)
  if not state then
    return nil, err
  end
  return table.concat({
    "Ralph mode is active.",
    "",
    "Primary task:",
    state.task_description,
    "",
    "State:",
    compact_state_json(state),
    "",
    "Work policy:",
    "- Continue until the task is complete, blocked, failed, cancelled, or needs user help.",
    "- Do not reduce scope or claim completion without fresh verification evidence.",
    "- Use tools to inspect, edit, run tests, and verify the result.",
    "- Use the ralph_state tool to write state directly, like oh-my-codex state_write.",
    "- For phase changes, call ralph_state with current_phase=\"executing\", current_phase=\"verifying\", or current_phase=\"fixing\".",
    "- When verified complete, call ralph_state with active=false, current_phase=\"complete\", and evidence.",
    "- When fundamentally blocked or user help is required, call ralph_state with active=false, current_phase=\"failed\", and stop_reason.",
    "- A normal assistant message saying the work is done does not stop Ralph; terminal Ralph state does.",
  }, "\n")
end

local function mark_max_iterations(state)
  state.active = false
  state.current_phase = "failed"
  state.stop_reason = "max_iterations_reached"
  state.completed_at = now()
  M.write(state)
  return nil
end

function M.follow_up_prompt(state)
  return table.concat({
    "Ralph loop active continue.",
    "",
    "State:",
    compact_state_json(state),
    "",
    "Continue the primary task from the current state. If work remains, do the next concrete step now.",
    "If implementation is complete, move to verification and gather fresh evidence.",
    "Only stop by calling ralph_state with active=false and current_phase=\"complete\", \"failed\", or \"cancelled\".",
  }, "\n")
end

function M.next_follow_up(_last_reply)
  local state = M.read()
  if not M.is_active(state) then
    return nil
  end
  state.iteration = (tonumber(state.iteration) or 0) + 1
  if state.current_phase == "starting" then
    state.current_phase = "executing"
  end
  if state.iteration >= (tonumber(state.max_iterations) or DEFAULT_MAX_ITERATIONS) then
    return mark_max_iterations(state)
  end
  local ok, updated = M.write(state)
  if not ok then
    return nil
  end
  return M.follow_up_prompt(updated)
end

function M.queue_follow_up_if_active(last_reply)
  local text = M.next_follow_up(last_reply)
  if not text then
    return false
  end
  local control = require("psi.agent_control")
  return control.queue_follow_up(text), text
end

function M.status_text()
  local state = M.read()
  if not state then
    return "ralph: inactive"
  end
  local lines = {
    "ralph: " .. (state.active and "active" or "inactive"),
    "phase: " .. tostring(state.current_phase or "-"),
    "iteration: " .. tostring(state.iteration or 0) .. "/" .. tostring(state.max_iterations or 0),
  }
  if type(state.task_description) == "string" and state.task_description ~= "" then
    lines[#lines + 1] = "task: " .. state.task_description
  end
  if type(state.stop_reason) == "string" and state.stop_reason ~= "" then
    lines[#lines + 1] = "stop_reason: " .. state.stop_reason
  end
  if type(state.completed_at) == "string" and state.completed_at ~= "" then
    lines[#lines + 1] = "completed_at: " .. state.completed_at
  end
  return table.concat(lines, "\n")
end

function M.phase_is_active(phase)
  phase = normalize_phase(phase)
  return phase ~= nil and ACTIVE_PHASES[phase] == true
end

function M.phase_is_terminal(phase)
  phase = normalize_phase(phase)
  return phase ~= nil and TERMINAL_PHASES[phase] == true
end

return M
