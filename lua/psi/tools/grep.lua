local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path")
local helpers = require("psi.tool_helpers")
local shell = require("psi.tool_shell")

local function build_argv(pattern, path, glob, limit, context, ignore_case, literal)
  local argv = {
    "rg",
    "-n",
    "--no-heading",
    "--color",
    "never",
    "--hidden",
    "--max-count",
    tostring(limit),
  }
  if context and context > 0 then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = tostring(context)
  end
  if ignore_case then
    argv[#argv + 1] = "-i"
  end
  if literal then
    argv[#argv + 1] = "-F"
  end
  if glob then
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = glob
  end
  argv[#argv + 1] = pattern
  argv[#argv + 1] = path
  return argv
end

local function impl(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("grep", "missing string field: pattern")
  end
  local raw_path = registry.optional_string(input, "path", ".")
  local path = path_util.resolve(raw_path) or raw_path
  local glob = type(input.glob) == "string" and input.glob or nil
  local limit = registry.optional_number(input, "limit", 100)
  local context = registry.optional_number(input, "context", 0)
  local ignore_case = registry.optional_boolean(input, "ignoreCase", false)
  local literal = registry.optional_boolean(input, "literal", false)
  local argv = build_argv(pattern, path, glob, limit, context, ignore_case, literal)
  return shell.run_tool_argv("grep", argv, raw_path, true, meta)
end

return function()
  helpers.register(registry, records, {
    name = "grep",
    description = "Search file contents for a pattern and return matching lines with file paths and line numbers.",
    prompt_snippet = "Search file contents for patterns (prefer this over broad shell grep)",
    guidelines = { "Prefer grep over bash when searching file contents." },
    input_schema = helpers.schema_object({
      pattern = helpers.schema_type("string"),
      path = helpers.schema_type("string"),
      glob = helpers.schema_type("string"),
      ignoreCase = helpers.schema_type("boolean"),
      literal = helpers.schema_type("boolean"),
      context = helpers.schema_type("number"),
      limit = helpers.schema_type("number"),
    }, { "pattern" }),
    impl = impl,
  })
end
