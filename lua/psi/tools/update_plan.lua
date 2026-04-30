local records = require("psi.records")
local registry = require("psi.tool_registry")
local helpers = require("psi.tool_helpers")
local plan = require("psi.plan")

local function impl(input)
  local items = input.plan
  local note = input.explanation
  local ok, result = plan.update(items, note)
  if not ok then
    return records.tool_failure("update_plan", result)
  end
  return records.new_tool_result(true, "update_plan", nil, {
    output = result,
    explanation = note,
    plan = plan.current(),
  })
end

return function()
  helpers.register(registry, records, {
    name = "update_plan",
    description = "Replace the visible task plan. Use for multi-step work; at most one item may be in_progress.",
    prompt_snippet = "Update the visible task plan",
    guidelines = {
      "Use update_plan for multi-step work and keep statuses current.",
      "Keep exactly one item in_progress while actively working through a plan.",
    },
    input_schema = helpers.schema_object({
      explanation = helpers.schema_type("string"),
      plan = {
        type = "array",
        items = helpers.schema_object({
          step = helpers.schema_type("string"),
          status = {
            type = "string",
            enum = { "pending", "in_progress", "completed" },
          },
        }, { "step", "status" }),
      },
    }, { "plan" }),
    impl = impl,
    opts = { execution_mode = "sequential" },
  })
end
