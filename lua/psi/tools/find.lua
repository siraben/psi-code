local records = require("psi.records")
local registry = require("psi.tool_registry")
local shell = require("psi.tool_shell")
local path_util = require("psi.path")
local helpers = require("psi.tool_helpers")
local truncate = require("psi.truncate")

local DEFAULT_BYTES = truncate.DEFAULT_MAX_BYTES

local function impl(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("find", "missing string field: pattern")
  end
  local raw_path = registry.optional_string(input, "path", ".")
  local path = path_util.resolve(raw_path) or raw_path
  local limit = registry.optional_number(input, "limit", 1000)
  local argv = { "fd", "--hidden", "--max-results", tostring(limit), "--glob", pattern, path }

  local tool_call_id = meta and meta.tool_call_id or nil
  local stream = shell.run_streaming_argv(argv, tool_call_id, {
    max_bytes = DEFAULT_BYTES,
    mode = "head",
    spill_to_disk = false,
  })
  local raw = stream.output or ""
  -- find tool: head-truncate by bytes only — line cap is enforced by
  -- fd's --max-results.
  local result = truncate.truncate_head(raw, {
    max_bytes = DEFAULT_BYTES,
    max_lines = math.huge,
  })

  local extras = {
    path = raw_path,
    argv = argv,
    status = stream.status,
    total_bytes = stream.total_bytes,
  }

  local output_text = result.content
  if result.truncated then
    extras.truncated = true
    local notice = truncate.head_notice(result)
    if notice and notice ~= "" then
      if #output_text > 0 then
        output_text = output_text .. "\n\n" .. notice
      else
        output_text = notice
      end
    end
  else
    extras.truncated = false
  end
  extras.output = output_text

  local ok = (stream.status == 0)
  return records.new_tool_result(ok, "find", nil, extras)
end

return function()
  helpers.register(registry, records, {
    name = "find",
    description = string.format(
      "Find files by glob pattern relative to a directory. Output is truncated to "
        .. "%dKB. Use limit= to cap result count.",
      math.floor(DEFAULT_BYTES / 1024)
    ),
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
