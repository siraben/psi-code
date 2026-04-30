-- psi.plan: shared plan-mode state and task-plan storage.

local settings = require("psi.settings")

local M = {}

local active = false
local model_override = nil
local current_plan = {}
local explanation = nil

local VALID_STATUS = {
  pending = true,
  in_progress = true,
  completed = true,
}

local PLAN_PROMPT = table.concat({
  "Plan mode is active. Focus on understanding, outlining, and asking only necessary clarifying questions.",
  " Do not edit files or make persistent changes unless the user explicitly asks you to leave plan mode and implement.",
  " Use update_plan for meaningful multi-step work so progress is visible in the UI.",
})

function M.is_active()
  return active
end

function M.set_active(value)
  active = value and true or false
  return active
end

function M.toggle()
  active = not active
  return active
end

function M.set_model(model)
  if type(model) == "string" and model ~= "" then
    model_override = model
  else
    model_override = nil
  end
end

function M.model(_fallback)
  local env = os.getenv("PSI_PLAN_MODEL")
  if env and env ~= "" then
    return env
  end
  if model_override and model_override ~= "" then
    return model_override
  end
  local configured = settings.get("plan.model", nil)
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return "openai-codex/gpt-5.5"
end

function M.prompt_suffix()
  if not active then
    return ""
  end
  return "\n\n" .. PLAN_PROMPT
end

function M.validate_plan(items)
  if type(items) ~= "table" then
    return nil, "plan must be an array"
  end
  local out = {}
  local in_progress = 0
  for i, item in ipairs(items) do
    if type(item) ~= "table" then
      return nil, "plan item " .. tostring(i) .. " must be an object"
    end
    local step = item.step
    local status = item.status
    if type(step) ~= "string" or step == "" then
      return nil, "plan item " .. tostring(i) .. " is missing step"
    end
    if type(status) ~= "string" or not VALID_STATUS[status] then
      return nil, "plan item " .. tostring(i) .. " has invalid status: " .. tostring(status)
    end
    if status == "in_progress" then
      in_progress = in_progress + 1
    end
    out[#out + 1] = { step = step, status = status }
  end
  if in_progress > 1 then
    return nil, "at most one plan item can be in_progress"
  end
  return out, nil
end

function M.update(items, note)
  local validated, err = M.validate_plan(items)
  if not validated then
    return false, err
  end
  current_plan = validated
  explanation = type(note) == "string" and note ~= "" and note or nil
  return true, M.summary()
end

function M.reset()
  current_plan = {}
  explanation = nil
end

function M.current()
  local out = {}
  for i, item in ipairs(current_plan) do
    out[i] = { step = item.step, status = item.status }
  end
  return out
end

function M.summary()
  local lines = {}
  if explanation and explanation ~= "" then
    lines[#lines + 1] = explanation
  end
  if #current_plan == 0 then
    lines[#lines + 1] = "plan is empty"
  else
    for _, item in ipairs(current_plan) do
      lines[#lines + 1] = string.format("- [%s] %s", item.status, item.step)
    end
  end
  return table.concat(lines, "\n")
end

function M.status_text()
  if #current_plan == 0 then
    return ""
  end
  local done = 0
  local active_step = nil
  for _, item in ipairs(current_plan) do
    if item.status == "completed" then
      done = done + 1
    elseif item.status == "in_progress" and active_step == nil then
      active_step = item.step
    end
  end
  local text = tostring(done) .. "/" .. tostring(#current_plan)
  if active_step and active_step ~= "" then
    text = text .. " " .. active_step
  end
  return text
end

return M
