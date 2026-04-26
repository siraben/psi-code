local records = require("psi.records")
local registry = require("psi.tool_registry")
local shell = require("psi.tool_shell")
local helpers = require("psi.tool_helpers")

local function impl(input, meta)
  local command = registry.require_string(input, "command")
  if not command then
    return records.tool_failure("bash", "missing string field: command")
  end
  return shell.run_tool("bash", command, nil, true, meta)
end

return function()
  helpers.register(registry, records, {
    name = "bash",
    description = "Execute a shell command in the current working directory and return its output.",
    prompt_snippet = "Execute bash commands (ls, rg, find, tests, git, build commands)",
    guidelines = { "Use bash for commands such as ls, rg, find, git, and tests." },
    input_schema = helpers.schema_object({
      command = helpers.schema_type("string"),
      timeout = helpers.schema_type("number"),
    }, { "command" }),
    impl = impl,
  })
end
