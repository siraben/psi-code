-- psi.message_transform: shared transcript cleanup helpers.
--
-- Provider modules still own their wire format, but the cross-provider
-- invariants live here: skip failed assistant turns, flatten text
-- content, convert session records to plain alists, and interpret
-- tool-result termination hints.

local prelude = require("psi.prelude")
local session_mod = require("psi.session")

local M = {}

local safe_decode = prelude.safe_json_decode

function M.plain_session()
  local session_messages = session_mod.messages()
  local plain = {}
  for i, m in ipairs(session_messages) do
    plain[i] = { role = m.role, text = m.text, data = m.data }
  end
  return plain
end

function M.message_body(entry)
  local body = safe_decode(entry and entry.data)
  return type(body) == "table" and body.message or nil, body
end

function M.skip_assistant(message)
  if type(message) ~= "table" then
    return false
  end
  local stop = message.stopReason
  return stop == "aborted" or stop == "error"
end

function M.text_from_content(content)
  local text = ""
  for _, block in ipairs(content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      text = (text == "" and block.text) or (text .. block.text)
    end
  end
  return text
end

function M.tool_result_text(message)
  if type(message) ~= "table" or type(message.content) ~= "table" then
    return ""
  end
  return M.text_from_content(message.content)
end

function M.all_results_terminate(results)
  if type(results) ~= "table" or #results == 0 then
    return false
  end
  for _, result in ipairs(results) do
    local value = result
    if result and result.ok and result.values and result.values.n > 0 then
      value = result.values[1]
    end
    if type(value) ~= "table" or value.terminate ~= true then
      return false
    end
  end
  return true
end

return M
