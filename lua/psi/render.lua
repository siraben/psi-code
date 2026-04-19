-- psi.render: hooks, tool-frame tracking, event rendering.

local records = require("psi.records")
local prelude = require("psi.prelude")
local ansi = require("psi.ansi")
local diff = require("psi.diff")
local io_lib = require("psi.io")

local M = {}

-- ---------- hooks ----------

local hooks = {}  -- {event_name = {fn1, fn2, ...}}

function M.register_hook(event, fn)
  hooks[event] = hooks[event] or {}
  table.insert(hooks[event], fn)
end

function M.run_hooks(event, payload)
  local results = {}
  local chain = hooks[event]
  if not chain then return results end
  for _, fn in ipairs(chain) do
    results[#results + 1] = fn(payload)
  end
  return results
end

local function render_hook_results(results)
  local pieces = {}
  for _, item in ipairs(results) do
    if type(item) == "string" then pieces[#pieces + 1] = item end
  end
  return table.concat(pieces)
end

function M.handle_event(event, payload)
  return render_hook_results(M.run_hooks(event, payload))
end

-- ---------- tool frames ----------

local frames = {}  -- id -> ToolFrame

function M.store_frame(id, frame) frames[id] = frame end
function M.lookup_frame(id)      return frames[id] end
function M.remove_frame(id)      frames[id] = nil end

-- ---------- renderer helpers ----------

local function tool_banner(tool, path)
  return "\n" .. ansi.bold(ansi.cyan(tool)) .. (path and (" " .. path) or "") .. "\n"
end

local function payload_tool(p)   return p.tool end
local function payload_id(p)     return p.id end
local function payload_input(p)  return p.input or {} end
local function payload_result(p)
  return records.tool_result_from_alist(p.result or {})
end

local function error_line(tool_name, result)
  return ansi.red(tool_name .. " failed") ..
    ": " ..
    (result.error or "unknown error") ..
    "\n"
end

-- ---------- per-tool call renderers ----------

local function render_read_call(p)
  return tool_banner("read", payload_input(p).path)
end

local function render_bash_call(p)
  local command = payload_input(p).command or ""
  return "\n" .. ansi.bold(ansi.cyan("$")) .. " " .. command .. "\n"
end

local function render_write_call(p)
  return tool_banner("write", payload_input(p).path)
end

local function render_edit_call(p)
  local input = payload_input(p)
  local edits = input.edits
  local count = (type(edits) == "table" and #edits > 0) and #edits or 1
  return tool_banner("edit", input.path) ..
    ansi.dim("planned edits: " .. tostring(count)) .. "\n"
end

local function render_search_call(tool, p)
  local input = payload_input(p)
  local pattern = input.pattern
  local path = input.path or "."
  local banner = tool_banner(tool, path)
  if pattern then
    return banner .. ansi.dim("pattern: " .. pattern) .. "\n"
  end
  return banner
end

local function render_lua_call(p)
  local mode = payload_input(p).mode or "summary"
  return "\n" .. ansi.bold(ansi.cyan("lua")) .. " " .. mode .. "\n"
end

local function render_generic_call(p)
  return tool_banner(payload_tool(p) or "tool", payload_input(p).path)
end

-- ---------- per-tool result renderers ----------

local function render_read_result(p, frame)
  local result = payload_result(p)
  local path = frame and frame.path
  if result.ok then
    return ansi.dim("completed read") .. (path and (" " .. path) or "") .. "\n"
  end
  return error_line("read", result)
end

local function render_bash_result(p)
  local result = payload_result(p)
  local status = result:get("status")
  local output = result:get("output")
  local status_str = tostring(status)
  local banner = result.ok
    and ansi.dim("command finished with status " .. status_str)
     or ansi.red("command failed with status " .. status_str)
  local out_block = ""
  if type(output) == "string" and #output > 0 then
    out_block = diff.preview_output(output) .. "\n"
  end
  return banner .. "\n" .. out_block
end

local function render_write_result(p, frame)
  local result = payload_result(p)
  local input = frame and frame.input
  local path = (frame and frame.path) or result:get("path") or (input and input.path)
  local before_text = frame and frame.before_text
  local after_text = path and io_lib.safe_read(path)
  local content = input and (input.content or input.text)
  if result.ok then
    local header = ansi.dim((before_text and "updated " or "created ") .. path)
    return header .. "\n" ..
      diff.colored_diff(before_text, after_text or content or "") .. "\n"
  end
  return error_line("write", result)
end

local function render_edit_result(p, frame)
  local result = payload_result(p)
  local path = (frame and frame.path) or result:get("path")
  local before_text = frame and frame.before_text
  local after_text = path and io_lib.safe_read(path)
  if result.ok then
    return ansi.dim("updated " .. path) .. "\n" ..
      diff.colored_diff(before_text, after_text or "") .. "\n"
  end
  return error_line("edit", result)
end

local function render_search_result(p)
  local result = payload_result(p)
  local output = result:get("output")
  if result.ok then
    if type(output) == "string" and #output > 0 then
      return diff.preview_output(output) .. "\n"
    end
    return ansi.dim("no output") .. "\n"
  end
  return error_line("tool", result)
end

local function render_lua_result(p)
  local result = payload_result(p)
  local text = result:get("result") or ""
  if result.ok then return diff.preview_output(text) .. "\n" end
  return error_line("lua", result)
end

local function render_generic_result(p)
  local result = payload_result(p)
  if result.ok then return ansi.dim("tool completed") .. "\n" end
  return ansi.red("tool failed: " .. (result.error or "unknown error")) .. "\n"
end

-- ---------- dispatch ----------

function M.render_tool_call(p)
  local tool = payload_tool(p)
  if tool == "read"  then return render_read_call(p) end
  if tool == "bash"  then return render_bash_call(p) end
  if tool == "write" then return render_write_call(p) end
  if tool == "edit"  then return render_edit_call(p) end
  if tool == "grep"  then return render_search_call("grep", p) end
  if tool == "find"  then return render_search_call("find", p) end
  if tool == "ls"    then return render_search_call("ls", p) end
  if tool == "lua"   then return render_lua_call(p) end
  return render_generic_call(p)
end

function M.render_tool_result(p)
  local tool = payload_tool(p)
  local frame = payload_id(p) and M.lookup_frame(payload_id(p))
  if tool == "read"  then return render_read_result(p, frame) end
  if tool == "bash"  then return render_bash_result(p, frame) end
  if tool == "write" then return render_write_result(p, frame) end
  if tool == "edit"  then return render_edit_result(p, frame) end
  if tool == "grep" or tool == "find" or tool == "ls" then
    return render_search_result(p)
  end
  if tool == "lua"   then return render_lua_result(p, frame) end
  return render_generic_result(p, frame)
end

-- ---------- frame capture/release ----------

function M.capture_frame(p)
  local tool = payload_tool(p)
  local input = payload_input(p)
  local id = payload_id(p)
  local path = input.path
  local before_text
  if path and (tool == "write" or tool == "edit") then
    before_text = io_lib.safe_read(path)
  end
  if id then
    M.store_frame(id, records.new_tool_frame(tool, input, path, before_text))
  end
  return nil
end

function M.release_frame(p)
  local id = payload_id(p)
  if id then M.remove_frame(id) end
  return nil
end

return M
