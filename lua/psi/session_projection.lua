-- Session/context reduction ported from Pi 1.4.0 (MIT, Mario Zechner):
-- core/session-manager.ts, core/messages.ts, ai/utils/{transcript,text}.ts.
-- Raw entries remain immutable; only the active model projection is edited.
local prelude = require("psi.prelude")
local M = {}

function M.is_null(value)
  return value == nil or value == psi.json_null
end

function M.copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = M.copy(item)
  end
  return setmetatable(out, getmetatable(value))
end

function M.keys(value)
  local out, seen = {}, {}
  local meta = getmetatable(value)
  for _, key in ipairs(meta and meta.__jsonorder or {}) do
    if value[key] ~= nil and not seen[key] then
      out[#out + 1], seen[key] = key, true
    end
  end
  local extra = {}
  for key in pairs(value) do
    if not seen[key] then
      extra[#extra + 1] = key
    end
  end
  table.sort(extra)
  for _, key in ipairs(extra) do
    out[#out + 1] = key
  end
  return out
end

function M.content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text or ""
    end
  end
  return table.concat(parts, "\n")
end

local function timestamp(value)
  if type(value) == "number" then
    return value
  end
  local y, m, d, h, minute, second, fraction =
    tostring(value):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)Z$")
  if not y then
    return 0
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  local months = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }
  local prior = y - 1
  local days = 365 * prior
    + math.floor(prior / 4)
    - math.floor(prior / 100)
    + math.floor(prior / 400)
    + (months[m] or 0)
    + d
    - 1
    - 719162
  if m > 2 and y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
    days = days + 1
  end
  return (((days * 24 + tonumber(h)) * 60 + tonumber(minute)) * 60 + tonumber(second)) * 1000
    + tonumber((fraction .. "000"):sub(1, 3))
end

function M.entry_messages(entry)
  if entry.type == "message" and type(entry.message) == "table" then
    local message = M.copy(entry.message)
    if
      M.is_null(message.content)
      and (
        message.role == "system"
        or message.role == "user"
        or message.role == "assistant"
        or message.role == "toolResult"
      )
    then
      message.content = message.role == "system" and "" or prelude.as_array({})
    end
    return { message }
  elseif entry.type == "custom_message" then
    if type(entry.message) == "table" then
      -- Read psi's earlier nested custom-message representation too.
      local message = M.copy(entry.message)
      if message.hidden then
        return {}
      end
      message.role = message.role == "assistant" and "assistant" or "custom"
      message.customType = message.customType or entry.customType or "psi"
      message.display = message.display ~= false and not message.hidden
      message.content = M.is_null(message.content) and prelude.as_array({}) or message.content
      return { message }
    end
    return {
      {
        role = "custom",
        customType = entry.customType,
        content = M.is_null(entry.content) and prelude.as_array({}) or M.copy(entry.content),
        display = entry.display,
        details = M.copy(entry.details),
        timestamp = timestamp(entry.timestamp),
      },
    }
  elseif entry.type == "compaction" then
    local out = {}
    if type(entry.systemMessage) == "table" then
      out[#out + 1] = M.copy(entry.systemMessage)
    end
    out[#out + 1] = {
      role = "compactionSummary",
      summary = entry.summary or "",
      tokensBefore = entry.tokensBefore,
      timestamp = timestamp(entry.timestamp),
    }
    return out
  elseif
    entry.type == "branch_summary"
    and type(entry.summary) == "string"
    and entry.summary ~= ""
  then
    return {
      {
        role = "branchSummary",
        summary = entry.summary,
        fromId = entry.fromId,
        timestamp = timestamp(entry.timestamp),
      },
    }
  end
  return {}
end

function M.build(path)
  local selected, compact_at = {}, nil
  for i, entry in ipairs(path) do
    if entry.type == "compaction" then
      compact_at = i
    end
  end
  if compact_at then
    local compaction = path[compact_at]
    selected[1] = compaction
    local keep = false
    for i = 1, compact_at - 1 do
      local entry = path[i]
      if entry.id == compaction.firstKeptEntryId then
        keep = true
      end
      if
        keep and not (entry.type == "message" and entry.message and entry.message.role == "system")
      then
        selected[#selected + 1] = entry
      end
    end
    for i = compact_at + 1, #path do
      selected[#selected + 1] = path[i]
    end
  else
    for _, entry in ipairs(path) do
      selected[#selected + 1] = entry
    end
  end
  local edits = {}
  for _, entry in ipairs(selected) do
    if entry.type == "context_edit" and type(entry.targetId) == "string" then
      edits[entry.targetId] = entry
    end
  end
  local out = { entries = {}, messages = {}, path = path }
  for _, entry in ipairs(path) do
    if entry.type == "thinking_level_change" then
      out.thinking_level = entry.thinkingLevel
    elseif entry.type == "model_change" then
      local provider, id = tostring(entry.model or ""):match("^([^/]+)/(.+)$")
      out.model = { provider = entry.provider or provider, modelId = entry.modelId or id }
    elseif
      entry.type == "message"
      and type(entry.message) == "table"
      and entry.message.role == "assistant"
      and entry.message.model
    then
      out.model = { provider = entry.message.provider, modelId = entry.message.model }
    end
  end
  for i, source in ipairs(selected) do
    local messages = source.type == "compaction" and i > 1 and {} or M.entry_messages(source)
    local edit = edits[source.id]
    if edit then
      if M.is_null(edit.replacement) then
        messages = {}
      elseif type(edit.replacement) == "table" then
        for _, message in ipairs(messages) do
          if
            message.role == "user"
            or message.role == "assistant"
            or message.role == "toolResult"
            or message.role == "custom"
          then
            message.content = M.copy(edit.replacement.content)
            if M.is_null(message.content) then
              message.content = prelude.as_array({})
            end
            if
              (message.role == "assistant" or message.role == "toolResult")
              and type(message.content) == "string"
            then
              message.content = prelude.as_array({ { type = "text", text = message.content } })
            end
          end
        end
      end
    end
    out.entries[#out.entries + 1] = { source_entry = source, messages = messages }
    for _, message in ipairs(messages) do
      out.messages[#out.messages + 1] = message
    end
  end
  return out
end

local function remove_order(order, key)
  for i, item in ipairs(order) do
    if item == key then
      table.remove(order, i)
      return
    end
  end
end

function M.system_state(messages)
  local content, sections, order, tools, tool_order, first = {}, {}, {}, {}, {}, nil
  for _, message in ipairs(messages) do
    if message.role == "system" then
      first = first or message.timestamp or 0
      local text = M.content_text(message.content)
      if text ~= "" then
        content[#content + 1] = text
      end
      for _, name in ipairs(M.keys(type(message.sections) == "table" and message.sections or {})) do
        local value = message.sections[name]
        if M.is_null(value) then
          sections[name] = nil
          remove_order(order, name)
        else
          if sections[name] == nil then
            order[#order + 1] = name
          end
          sections[name] = value
        end
      end
      for _, tool in ipairs(type(message.toolsRemoved) == "table" and message.toolsRemoved or {}) do
        tools[tool.name] = nil
        remove_order(tool_order, tool.name)
      end
      for _, tool in ipairs(type(message.toolsAdded) == "table" and message.toolsAdded or {}) do
        if tools[tool.name] == nil then
          tool_order[#tool_order + 1] = tool.name
        end
        tools[tool.name] = M.copy(tool)
      end
    end
  end
  if first == nil then
    return nil
  end
  local declarations = prelude.as_array({})
  for _, name in ipairs(tool_order) do
    declarations[#declarations + 1] = tools[name]
  end
  local state = { role = "system", content = table.concat(content, "\n\n"), timestamp = first }
  if #order > 0 then
    state.sections = prelude.ordered_object(order, sections)
  end
  if #declarations > 0 then
    state.toolsAdded = declarations
  end
  return state
end

function M.system_text(message)
  if not message then
    return ""
  end
  local parts = {}
  local text = M.content_text(message.content)
  if text ~= "" then
    parts[#parts + 1] = text
  end
  for _, name in ipairs(M.keys(message.sections or {})) do
    local value = message.sections[name]
    if not M.is_null(value) and value ~= "" then
      parts[#parts + 1] = value
    end
  end
  return table.concat(parts, "\n\n")
end

function M.summary_text(role, summary)
  if role == "branchSummary" or role == "branch-summary" then
    return "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
      .. (summary or "")
      .. "</summary>"
  end
  return "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
    .. (summary or "")
    .. "\n</summary>"
end

function M.bash_text(message)
  local out = "Ran `" .. (message.command or "") .. "`\n"
  out = out
    .. (
      (message.output and message.output ~= "") and ("```\n" .. message.output .. "\n```")
      or "(no output)"
    )
  if message.cancelled then
    out = out .. "\n\n(command cancelled)"
  elseif not M.is_null(message.exitCode) and message.exitCode ~= 0 then
    out = out .. "\n\nCommand exited with code " .. tostring(message.exitCode)
  end
  if message.truncated and message.fullOutputPath then
    out = out .. "\n\n[Output truncated. Full output: " .. message.fullOutputPath .. "]"
  end
  return out
end

-- Bridge canonical messages to psi's existing provider adapters. No foreign
-- tool definitions, credentials, extensions, or commands are executed here.
function M.records(projection)
  local out = {}
  for _, projected in ipairs(projection.entries) do
    for _, original in ipairs(projected.messages) do
      local message = M.copy(original)
      local role = message.role
      local body = {
        id = projected.source_entry.id,
        timestamp = projected.source_entry.timestamp,
        parentId = projected.source_entry.parentId,
        message = message,
      }
      if role == "compactionSummary" then
        for _, key in ipairs({
          "details",
          "readFiles",
          "modifiedFiles",
          "firstKeptEntryId",
          "tokensBefore",
          "fromHook",
        }) do
          body[key] = M.copy(projected.source_entry[key])
        end
        role, body.summary = "compaction-summary", message.summary
      elseif role == "branchSummary" then
        body.details = M.copy(projected.source_entry.details)
        role, body.summary = "branch-summary", message.summary
      elseif role == "toolResult" then
        role = "tool-result"
      elseif role == "custom" then
        body.__entry_type = "custom_message"
      elseif role == "bashExecution" then
        if not message.excludeFromContext then
          role, message.role, message.content =
            "user", "user", prelude.as_array({ { type = "text", text = M.bash_text(message) } })
        else
          role = nil
        end
      elseif role ~= "user" and role ~= "assistant" and role ~= "system" then
        role = nil
      end
      if role then
        out[#out + 1] = {
          role = role,
          text = message.summary or M.content_text(message.content),
          data = psi.json_encode(body),
        }
      end
    end
  end
  return out
end

-- Pi's chars/4 estimate counts JavaScript UTF-16 code units, not UTF-8 bytes.
local function chars(value)
  local count = 0
  for _, cp in utf8.codes(prelude.decode_utf8_lossy(tostring(value or ""))) do
    count = count + (cp > 0xffff and 2 or 1)
  end
  return count
end

function M.truncate_for_summary(text, limit)
  text = prelude.decode_utf8_lossy(text or "")
  local length = chars(text)
  if length <= limit then
    return text
  end
  local count, finish = 0, 0
  for pos, cp in utf8.codes(text) do
    count = count + (cp > 0xffff and 2 or 1)
    if count > limit then
      break
    end
    finish = (utf8.offset(text, 2, pos) or (#text + 1)) - 1
  end
  return text:sub(1, finish) .. "\n\n[... " .. (length - limit) .. " more characters truncated]"
end

local function content_chars(content)
  if type(content) == "string" then
    return chars(content)
  end
  local total = 0
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" then
      total = total + chars(block.text)
    elseif block.type == "image" then
      total = total + 4800
    end
  end
  return total
end

function M.estimate_tokens(message)
  local total = 0
  if message.role == "system" then
    total = content_chars(message.content)
    for _, value in pairs(message.sections or {}) do
      if type(value) == "string" then
        total = total + chars(value)
      end
    end
    if message.toolsAdded then
      total = total + chars(psi.json_encode(message.toolsAdded))
    end
  elseif message.role == "assistant" then
    for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
      if block.type == "text" then
        total = total + chars(block.text)
      elseif block.type == "thinking" then
        total = total + chars(block.thinking)
      elseif block.type == "toolCall" then
        total = total + chars(block.name) + chars(psi.json_encode(block.arguments or {}))
      end
    end
  elseif message.role == "compactionSummary" or message.role == "branchSummary" then
    total = chars(message.summary)
  elseif message.role == "bashExecution" then
    total = chars(message.command) + chars(message.output)
  else
    total = content_chars(message.content)
  end
  return math.ceil(total / 4)
end

return M
