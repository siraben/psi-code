local records = require("psi.records")
local registry = require("psi.tool_registry")
local shell = require("psi.tool_shell")
local helpers = require("psi.tool_helpers")
local truncate = require("psi.truncate")

local DEFAULT_LINES = truncate.DEFAULT_MAX_LINES
local DEFAULT_BYTES = truncate.DEFAULT_MAX_BYTES

local function impl(input, meta)
  local command = registry.require_string(input, "command")
  if not command then
    return records.tool_failure("bash", "missing string field: command")
  end

  local tool_call_id = meta and meta.tool_call_id or nil
  local stream = shell.run_streaming(command, tool_call_id, {
    max_bytes = DEFAULT_BYTES,
    max_lines = DEFAULT_LINES,
    mode = "tail",
    progress = "truncated",
    truncate_final = true,
    notice = "tail",
  })

  -- If tail-truncation kicked in (or the underlying C buffer dropped
  -- bytes) we want a temp-file spillover hint for the model. The
  -- streaming runner already wrote the temp file when total_bytes
  -- exceeded the cap — surface its path here.
  local extras = {
    command = command,
    status = stream.status,
    total_bytes = stream.total_bytes,
  }

  local output_text = stream.output or ""
  if stream.truncated then
    extras.truncated = true
    extras.temp_file_path = stream.temp_file_path
    extras.truncation = stream.truncation_meta
  else
    extras.truncated = false
  end

  extras.output = output_text

  local ok = (stream.status == 0)
  if not ok and (stream.status ~= nil) then
    -- Surface the exit code in the output so the model can react.
    if #output_text > 0 then
      output_text = output_text .. "\n\nCommand exited with code " .. tostring(stream.status)
    else
      output_text = "Command exited with code " .. tostring(stream.status)
    end
    extras.output = output_text
  end

  return records.new_tool_result(ok, "bash", nil, extras)
end

return function()
  helpers.register(registry, records, {
    name = "bash",
    description = string.format(
      "Execute a shell command in the current working directory and return its output. "
      .. "Output is tail-truncated to the last %d lines or %dKB (whichever is hit first). "
      .. "When truncated, the full output is also saved to a temp file whose path is "
      .. "returned in the result; use the read tool with that path to inspect more.",
      DEFAULT_LINES, math.floor(DEFAULT_BYTES / 1024)
    ),
    prompt_snippet = "Execute bash commands (ls, rg, find, tests, git, build commands)",
    guidelines = { "Use bash for commands such as ls, rg, find, git, and tests." },
    input_schema = helpers.schema_object({
      command = helpers.schema_type("string"),
      timeout = helpers.schema_type("number"),
    }, { "command" }),
    impl = impl,
  })
end
