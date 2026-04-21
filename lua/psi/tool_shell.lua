-- psi.tool_shell: POSIX shell quoting and command-result wrapping.

local records = require("psi.records")

local M = {}

-- Wraps text in single quotes with '\'' escapes for embedded quotes.
function M.quote(text)
  if text == nil then
    return "''"
  end
  local parts = { "'" }
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "'" then
      parts[#parts + 1] = "'\\''"
    else
      parts[#parts + 1] = ch
    end
  end
  parts[#parts + 1] = "'"
  return table.concat(parts)
end

function M.process_result(command)
  return records.process_result_from_alist(psi.process_run(command))
end

-- Run a shell command and wrap as a ToolResult.
function M.run_tool(tool_name, command, path, keep_output_on_error)
  local proc = M.process_result(command)
  local ok = proc:ok()
  local include_output = keep_output_on_error or ok or (proc.output and #proc.output > 0)
  local extras = {}
  if path then
    extras.path = path
  end
  extras.command = command
  extras.status = proc.status
  extras.truncated = proc.truncated
  if include_output then
    extras.output = proc.output or ""
  end
  return records.new_tool_result(ok, tool_name, nil, extras)
end

return M
