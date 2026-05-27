-- psi.tools.write: Create or overwrite a file with the supplied content.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path_utils")
local mutation_queue = require("psi.file_mutation_queue")
local helpers = require("psi.tool_helpers")

local function impl(input)
  local raw_path = registry.require_string(input, "path")
  local content = input.content or input.text
  if not raw_path then
    return records.tool_failure("write", "missing string field: path")
  end
  if type(content) ~= "string" then
    return records.tool_failure("write", "missing string field: content")
  end
  local path = path_util.resolve(raw_path) or raw_path
  return mutation_queue.with_path(path, function()
    if not psi.mkdir_parent(path) then
      return records.tool_failure("write", "could not create parent directory")
    end
    if not psi.file_write(path, content) then
      return records.tool_failure("write", "could not write full file")
    end
    return records.new_tool_result(true, "write", nil, {
      path = raw_path,
      resolved_path = path_util.to_host(path),
      internal_path = path,
      bytes_written = #content,
    })
  end)
end

return function()
  helpers.register(registry, records, {
    name = "write",
    description = "Write content to a file. Creates the file if it does not exist, overwrites it if it does, and creates parent directories.",
    prompt_snippet = "Create or overwrite files",
    guidelines = { "Use write for new files or full rewrites." },
    input_schema = helpers.schema_object({
      path = helpers.schema_type("string"),
      content = helpers.schema_type("string"),
    }, { "path", "content" }),
    impl = impl,
  })
end
