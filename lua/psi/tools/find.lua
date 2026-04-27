local records = require("psi.records")
local registry = require("psi.tool_registry")
local shell = require("psi.tool_shell")
local path_util = require("psi.path")
local helpers = require("psi.tool_helpers")

local function impl(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("find", "missing string field: pattern")
  end
  local raw_path = registry.optional_string(input, "path", ".")
  local path = path_util.resolve(raw_path) or raw_path
  local limit = registry.optional_number(input, "limit", 1000)
  local argv = { "fd", "--hidden", "--max-results", tostring(limit), "--glob", pattern, path }
  return shell.run_tool_argv("find", argv, raw_path, true, meta)
end

return function()
  helpers.register(registry, records, {
    name = "find",
    description = "Find files by glob pattern relative to a directory.",
    prompt_snippet = "Find files by glob pattern",
    guidelines = { "Prefer find over bash when locating files." },
    input_schema = helpers.schema_object({
      pattern = helpers.schema_type("string"),
      path = helpers.schema_type("string"),
      limit = helpers.schema_type("number"),
    }, { "pattern" }),
    impl = impl,
  })
end
