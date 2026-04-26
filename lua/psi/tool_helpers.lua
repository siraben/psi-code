-- psi.tool_helpers: shared helpers for built-in tool modules.

local prelude = require("psi.prelude")

local M = {}

function M.schema_type(t)
  return { type = t }
end

function M.schema_object(properties, required)
  return {
    type = "object",
    properties = properties,
    required = prelude.as_array(required),
  }
end

function M.register(registry, records, spec)
  registry.register(
    records.new_tool(
      spec.name,
      spec.description,
      spec.prompt_snippet,
      spec.guidelines or {},
      spec.input_schema,
      spec.impl,
      spec.opts
    )
  )
end

return M
