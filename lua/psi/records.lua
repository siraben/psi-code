-- psi.records: typed-table constructors used across the Lua layer.
--
-- Each record is a plain table with a shared __index metatable carrying
-- the type tag. External data (event payloads, tool-call inputs) still
-- arrives as plain tables with string keys; from_alist converts those.

local M = {}

-- helper: make a record class with given fields.
local function make_class(tag)
  local class = {__kind = tag}
  class.__index = class
  return class
end

-- ---------- Message ----------

local Message = make_class("Message")
M.Message = Message

function M.new_message(role, text, data)
  return setmetatable({role = role, text = text or "", data = data}, Message)
end

function M.message_from_alist(t)
  return M.new_message(t.role, t.text, t.data)
end

function M.messages_from_alists(xs)
  local out = {}
  for i, entry in ipairs(xs) do out[i] = M.message_from_alist(entry) end
  return out
end

-- ---------- Tool ----------

local Tool = make_class("Tool")
M.Tool = Tool

function M.new_tool(name, description, prompt_snippet, guidelines, input_schema, impl)
  return setmetatable({
    name = name,
    description = description,
    prompt_snippet = prompt_snippet,
    guidelines = guidelines,     -- array of strings
    input_schema = input_schema, -- table (JSON-shaped)
    impl = impl,                 -- function(input) -> ToolResult
  }, Tool)
end

function M.tool_to_alist(tool)
  return {
    name = tool.name,
    description = tool.description,
    prompt_snippet = tool.prompt_snippet,
    prompt_guidelines = tool.guidelines,
    input_schema = tool.input_schema,
  }
end

-- ---------- ToolResult ----------

local ToolResult = make_class("ToolResult")
M.ToolResult = ToolResult

function M.new_tool_result(ok, tool, error, extras)
  return setmetatable({
    ok = ok and true or false,
    tool = tool,
    error = error,       -- string or nil
    extras = extras or {},
  }, ToolResult)
end

function ToolResult:get(key) return self.extras[key] end

function M.tool_success(tool, extras) return M.new_tool_result(true, tool, nil, extras or {}) end
function M.tool_failure(tool, message) return M.new_tool_result(false, tool, message, {}) end

function M.tool_result_to_alist(r)
  local t = {ok = r.ok, tool = r.tool}
  if r.error then t.error = r.error end
  for k, v in pairs(r.extras) do t[k] = v end
  return t
end

function M.tool_result_from_alist(t)
  if type(t) ~= "table" then
    return M.new_tool_result(false, "unknown", "invalid result", {})
  end
  local extras = {}
  for k, v in pairs(t) do
    if k ~= "ok" and k ~= "tool" and k ~= "error" then extras[k] = v end
  end
  return M.new_tool_result(t.ok and t.ok ~= false, t.tool or "unknown", t.error, extras)
end

-- ---------- ToolFrame ----------

local ToolFrame = make_class("ToolFrame")
M.ToolFrame = ToolFrame

function M.new_tool_frame(tool, input, path, before_text)
  return setmetatable({
    tool = tool,
    input = input,
    path = path,
    before_text = before_text,
  }, ToolFrame)
end

-- ---------- ProcessResult ----------

local ProcessResult = make_class("ProcessResult")
M.ProcessResult = ProcessResult

function M.new_process_result(output, status, truncated)
  return setmetatable({
    output = output or "",
    status = status or -1,
    truncated = truncated and true or false,
  }, ProcessResult)
end

function M.process_result_from_alist(t)
  return M.new_process_result(t.output, t.status, t.truncated)
end

function ProcessResult:ok() return self.status == 0 end

-- ---------- ContextFile ----------

local ContextFile = make_class("ContextFile")
M.ContextFile = ContextFile

function M.new_context_file(path, content)
  return setmetatable({path = path, content = content}, ContextFile)
end

-- ---------- CommandAction ----------

local CommandAction = make_class("CommandAction")
M.CommandAction = CommandAction

function M.new_command_action(kind, payload)
  return setmetatable({kind = kind, payload = payload}, CommandAction)
end

-- serialization expected by C: {kind-string, payload}
function M.command_action_to_list(action)
  return {action.kind, action.payload}
end

return M
