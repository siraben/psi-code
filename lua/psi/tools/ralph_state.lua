local helpers = require("psi.tool_helpers")
local records = require("psi.records")
local registry = require("psi.tool_registry")
local ralph = require("psi.ralph")

local function string_field(input, key)
  local value = input[key]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function has_evidence(state)
  if type(state.evidence) ~= "table" then
    return false
  end
  for _, item in ipairs(state.evidence) do
    if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
      return true
    end
    if type(item) == "string" and item ~= "" then
      return true
    end
  end
  return false
end

local function direct_state_write(input)
  local state = ralph.read()
  if not state then
    return records.tool_failure("ralph_state", "ralph is not active")
  end
  if not ralph.is_active(state) then
    return records.tool_failure("ralph_state", "ralph is not active")
  end

  for _, key in ipairs({
    "active",
    "iteration",
    "max_iterations",
    "current_phase",
    "task_description",
    "started_at",
    "completed_at",
    "stop_reason",
    "error",
  }) do
    if input[key] ~= nil then
      state[key] = input[key]
    end
  end

  local custom = input.state
  if type(custom) == "table" then
    for key, value in pairs(custom) do
      state[key] = value
    end
  end

  local evidence = string_field(input, "evidence")
  if evidence then
    state.evidence = type(state.evidence) == "table" and state.evidence or {}
    state.evidence[#state.evidence + 1] = {
      at = require("psi.prelude").iso_timestamp(),
      text = evidence,
    }
  end

  local phase = ralph.normalize_phase(state.current_phase)
  if state.active == false and not ralph.phase_is_terminal(phase) then
    return records.tool_failure(
      "ralph_state",
      "active=false requires terminal current_phase: complete, failed, or cancelled"
    )
  end

  if phase == "complete" and not has_evidence(state) then
    return records.tool_failure("ralph_state", "complete requires evidence")
  end

  local ok, state_or_err = ralph.write(state)
  if not ok then
    return records.tool_failure("ralph_state", state_or_err)
  end
  return records.tool_success("ralph_state", { state = state_or_err })
end

local function impl(input)
  input = input or {}

  -- Match oh-my-codex's state_write style: models can write mode state
  -- fields directly, e.g. {mode="ralph", active=false,
  -- current_phase="complete"}. The older action enum remains supported.
  local action = string_field(input, "action")
  if not action then
    if input.current_phase ~= nil
      or input.active ~= nil
      or input.iteration ~= nil
      or input.max_iterations ~= nil
      or input.state ~= nil
      or input.evidence ~= nil
      or input.stop_reason ~= nil
    then
      return direct_state_write(input)
    end
    action = "status"
  end
  action = action:lower()

  if action == "status" then
    local state = ralph.read()
    return records.tool_success("ralph_state", {
      state = state or { active = false, mode = "ralph" },
    })
  end

  if action == "phase" or action == "update" then
    local phase = input.phase or input.current_phase
    if not ralph.phase_is_active(phase) then
      return records.tool_failure(
        "ralph_state",
        "phase action requires phase: starting, executing, verifying, or fixing"
      )
    end
    local ok, state_or_err = ralph.update({
      phase = phase,
      evidence = input.evidence,
    })
    if not ok then
      return records.tool_failure("ralph_state", state_or_err)
    end
    return records.tool_success("ralph_state", { state = state_or_err })
  end

  if action == "complete" then
    if type(input.evidence) ~= "string" or input.evidence == "" then
      return records.tool_failure("ralph_state", "complete requires evidence")
    end
    local ok, state_or_err = ralph.update({
      phase = "complete",
      evidence = input.evidence,
      stop_reason = input.stop_reason or "verified_complete",
    })
    if not ok then
      return records.tool_failure("ralph_state", state_or_err)
    end
    return records.tool_success("ralph_state", { state = state_or_err })
  end

  if action == "blocked" or action == "failed" then
    local reason = input.stop_reason or input.reason or action
    local ok, state_or_err = ralph.update({
      phase = "failed",
      evidence = input.evidence,
      stop_reason = reason,
    })
    if not ok then
      return records.tool_failure("ralph_state", state_or_err)
    end
    return records.tool_success("ralph_state", { state = state_or_err })
  end

  if action == "cancelled" or action == "cancel" then
    local ok, state_or_err = ralph.stop(input.stop_reason or "cancelled", "cancelled")
    if not ok then
      return records.tool_failure("ralph_state", state_or_err)
    end
    return records.tool_success("ralph_state", { state = state_or_err })
  end

  return records.tool_failure("ralph_state", "unsupported action: " .. tostring(input.action))
end

return function()
  registry.register(records.new_tool("ralph_state", "Read or update the active Ralph lifecycle state. Mirrors oh-my-codex state_write for mode=ralph: pass current_phase/active/iteration fields directly; action is optional.", "Update Ralph state directly, e.g. current_phase=verifying or active=false current_phase=complete", {
    "Use ralph_state during /ralph runs to write mode state directly, like state_write({mode='ralph', current_phase='verifying'}).",
    "For completion, call ralph_state with active=false, current_phase=complete, and evidence after fresh verification.",
    "The action field is optional; direct state fields are preferred.",
  }, helpers.schema_object({
    mode = helpers.schema_type("string"),
    action = helpers.schema_type("string"),
    active = helpers.schema_type("boolean"),
    iteration = helpers.schema_type("number"),
    max_iterations = helpers.schema_type("number"),
    phase = helpers.schema_type("string"),
    current_phase = helpers.schema_type("string"),
    task_description = helpers.schema_type("string"),
    evidence = helpers.schema_type("string"),
    stop_reason = helpers.schema_type("string"),
    reason = helpers.schema_type("string"),
    completed_at = helpers.schema_type("string"),
    state = helpers.schema_type("object"),
  }, {}), impl))
end
