-- User-requested ! / !! commands: run locally without a model turn.
local shell = require("psi.tool_shell")
local sched = require("psi.sched")
local session = require("psi.session_manager")

local M = {}

function M.parse(line)
  if type(line) ~= "string" or line:sub(1, 1) ~= "!" then
    return nil
  end
  local hidden = line:sub(1, 2) == "!!"
  return { command = line:sub(hidden and 3 or 2):match("^%s*(.-)%s*$"), hidden = hidden }
end

function M.run(request, on_output)
  if request.command == "" then
    return nil, "usage: ! <command> or !! <command> (excluded from context)"
  end
  psi.abort_reset()
  local result = sched.run(function()
    return shell.run_streaming(request.command, nil, {
      mode = "tail",
      truncate_final = true,
      notice = "tail",
      on_output = on_output,
    })
  end)
  result.aborted = result.aborted or psi.is_aborted()
  local status = result.aborted and "Command cancelled"
    or ("Command exited with code " .. tostring(result.status))
  local text = "$ " .. request.command .. "\n" .. (result.output or "") .. "\n" .. status
  session.append_custom_message(text, { role = "user", hidden = request.hidden })
  local saved, err = session.save()
  result.text = text
  result.save_error = not saved and err or nil
  return result
end

return M
