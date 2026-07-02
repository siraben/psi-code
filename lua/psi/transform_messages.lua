-- psi.message_transform: shared transcript cleanup helpers.
--
-- Provider modules still own their wire format, but the cross-provider
-- invariants live here: skip failed assistant turns, flatten text
-- content, convert session records to plain alists, and interpret
-- tool-result termination hints.

local prelude = require("psi.prelude")
local session_mod = require("psi.session_manager")

local M = {}

local safe_decode = prelude.safe_json_decode

-- Wire guard for text reaching a provider request: session appends are
-- already lossy-decoded, but system prompts / append_raw / extension text
-- can bypass that path. Valid input costs one scan and no allocation.
local function clean_text(text)
  return prelude.sanitize_surrogates(text or "")
end

local USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"
local TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"
M.USER_IMAGE_PLACEHOLDER = USER_IMAGE_PLACEHOLDER
M.TOOL_IMAGE_PLACEHOLDER = TOOL_IMAGE_PLACEHOLDER

function M.plain_session()
  local session_messages = session_mod.messages()
  local plain = prelude.array(#session_messages)
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
      local block_text = clean_text(block.text)
      text = (text == "" and block_text) or (text .. block_text)
    end
  end
  return text
end

function M.text_from_content_with_image_placeholder(content, placeholder)
  placeholder = placeholder or TOOL_IMAGE_PLACEHOLDER
  local parts = prelude.array(#(content or {}))
  local previous_placeholder = false
  for _, block in ipairs(content or {}) do
    if type(block) == "table" then
      if block.type == "image" then
        if not previous_placeholder then
          parts[#parts + 1] = placeholder
        end
        previous_placeholder = true
      elseif block.type == "text" and type(block.text) == "string" then
        local block_text = clean_text(block.text)
        parts[#parts + 1] = block_text
        previous_placeholder = block_text == placeholder
      end
    end
  end
  return table.concat(parts, "\n")
end

function M.has_images(content)
  if type(content) ~= "table" then
    return false
  end
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "image" then
      return true
    end
  end
  return false
end

function M.openai_chat_content(content)
  if not M.has_images(content) then
    return M.text_from_content(content)
  end
  local out = prelude.as_array({})
  for _, block in ipairs(content or {}) do
    if type(block) == "table" then
      if block.type == "text" then
        out[#out + 1] = { type = "text", text = clean_text(block.text) }
      elseif block.type == "image" and type(block.data) == "string" then
        out[#out + 1] = {
          type = "image_url",
          image_url = {
            url = "data:"
              .. tostring(block.mimeType or "application/octet-stream")
              .. ";base64,"
              .. block.data,
          },
        }
      end
    end
  end
  return out
end

function M.openai_response_content(content)
  local out = prelude.as_array({})
  for _, block in ipairs(content or {}) do
    if type(block) == "table" then
      if block.type == "text" then
        out[#out + 1] = { type = "input_text", text = clean_text(block.text) }
      elseif block.type == "image" and type(block.data) == "string" then
        out[#out + 1] = {
          type = "input_image",
          detail = "auto",
          image_url = "data:"
            .. tostring(block.mimeType or "application/octet-stream")
            .. ";base64,"
            .. block.data,
        }
      end
    end
  end
  if #out == 0 then
    out[#out + 1] = { type = "input_text", text = "" }
  end
  return out
end

function M.tool_result_text(message)
  if type(message) ~= "table" or type(message.content) ~= "table" then
    return ""
  end
  return M.text_from_content(message.content)
end

function M.replay_session(session, handlers)
  handlers = handlers or {}
  local pending_tool_calls = {}
  local seen_result_ids = {}
  local known_tool_use_ids = {}

  local function remember_tool_calls(calls)
    pending_tool_calls = type(calls) == "table" and calls or {}
    seen_result_ids = {}
    for _, call in ipairs(pending_tool_calls) do
      if call.id ~= nil and call.id ~= "" then
        known_tool_use_ids[call.id] = true
      end
    end
  end

  local function flush_synthetic_results()
    if #pending_tool_calls == 0 then
      return
    end
    if type(handlers.synthetic_tool_results) == "function" then
      local missing = nil
      for _, call in ipairs(pending_tool_calls) do
        if call.id ~= nil and call.id ~= "" and not seen_result_ids[call.id] then
          missing = missing or prelude.array(#pending_tool_calls)
          missing[#missing + 1] = call
        end
      end
      if missing and #missing > 0 then
        handlers.synthetic_tool_results(missing)
      end
    end
    pending_tool_calls = {}
    seen_result_ids = {}
  end

  local i, n = 1, #session
  while i <= n do
    local entry = session[i]
    local message, body = M.message_body(entry)
    local role = entry.role

    if role == "assistant" and message then
      if M.skip_assistant(message) then
        i = i + 1
      else
        flush_synthetic_results()
        if type(handlers.assistant) == "function" then
          remember_tool_calls(handlers.assistant(message, body, entry))
        else
          remember_tool_calls({})
        end
        i = i + 1
      end
    elseif role == "user" and message then
      flush_synthetic_results()
      if type(handlers.user) == "function" then
        handlers.user(message, body, entry)
      end
      i = i + 1
    elseif role == "tool-result" then
      local items = nil
      while i <= n and session[i].role == "tool-result" do
        local parsed = safe_decode(session[i].data)
        local tool_message = type(parsed) == "table" and parsed.message or nil
        if type(tool_message) == "table" and type(handlers.tool_result) == "function" then
          local id, item = handlers.tool_result(tool_message, parsed, session[i])
          if id ~= nil and id ~= "" and known_tool_use_ids[id] then
            items = items or prelude.array(1)
            items[#items + 1] = item
            seen_result_ids[id] = true
          end
        end
        i = i + 1
      end
      if items and #items > 0 and type(handlers.tool_results) == "function" then
        handlers.tool_results(items)
      end
    elseif role == "compaction-summary" then
      flush_synthetic_results()
      if type(handlers.compaction_summary) == "function" then
        handlers.compaction_summary(
          (type(body) == "table" and body.summary) or entry.text or "",
          body,
          entry
        )
      end
      i = i + 1
    elseif role == "branch-summary" then
      flush_synthetic_results()
      if type(handlers.branch_summary) == "function" then
        handlers.branch_summary(
          (type(body) == "table" and body.summary) or entry.text or "",
          body,
          entry
        )
      elseif type(handlers.compaction_summary) == "function" then
        handlers.compaction_summary(
          (type(body) == "table" and body.summary) or entry.text or "",
          body,
          entry
        )
      end
      i = i + 1
    elseif
      role == "custom"
      and type(body) == "table"
      and body.__entry_type == "custom_message"
      and type(body.message) == "table"
      and not body.message.hidden
    then
      flush_synthetic_results()
      if type(handlers.custom_message) == "function" then
        handlers.custom_message(body.message, body, entry)
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  flush_synthetic_results()
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
