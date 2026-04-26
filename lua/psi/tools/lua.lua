local records = require("psi.records")
local registry = require("psi.tool_registry")
local prelude = require("psi.prelude")
local helpers = require("psi.tool_helpers")

local function eval_to_string(expression)
  local ok, value = prelude.eval_expression(expression)
  if not ok then
    return "error: " .. tostring(value)
  end
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

local function impl(input)
  local mode = registry.optional_string(input, "mode", "summary")
  local expression = input.expression or input.code
  if mode == "summary" or mode == "inspect" then
    return records.new_tool_result(true, "lua", nil, {
      mode = mode,
      result = require("psi.prompt").runtime_summary(),
    })
  elseif mode == "eval" then
    if type(expression) ~= "string" then
      return records.tool_failure("lua", "missing string field: expression")
    end
    return records.new_tool_result(true, "lua", nil, {
      mode = mode,
      expression = expression,
      result = eval_to_string(expression),
    })
  end
  return records.tool_failure("lua", "unsupported mode")
end

return function()
  helpers.register(registry, records, {
    name = "lua",
    description = "Inspect or evaluate expressions in psi's embedded Lua runtime. Use this to inspect loaded helpers, prompt state, tool specs, or runtime environment.",
    prompt_snippet = "Inspect or evaluate the embedded Lua runtime and helper environment",
    guidelines = {
      "Use lua with mode summary to inspect the current runtime and helper environment.",
      "Use lua with mode eval and an expression string to inspect or interact with psi's Lua state.",
    },
    input_schema = helpers.schema_object({
      mode = helpers.schema_type("string"),
      expression = helpers.schema_type("string"),
      code = helpers.schema_type("string"),
    }, {}),
    impl = impl,
  })
end
