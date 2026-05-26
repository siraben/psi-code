-- Pi-style tool execution component rendering.

local ansi = require("psi.ansi")
local component = require("psi.tui_component")
local diff = require("psi.diff")
local diff_component = require("psi.tui_components.diff")
local text = require("psi.tui_text")

local M = {}

local ESC = string.char(27)
local RESET = ESC .. "[0m"

M.BG_PENDING = "48;5;236"
M.BG_SUCCESS = "48;5;22"
M.BG_ERROR = "48;5;52"

local FG_TITLE = "1"
local FG_ACCENT = "36"
local FG_MUTED = "38;5;242"
local FG_DIM = "90"
local FG_WARNING = "33"
local FG_ERROR = "31"

local PREVIEW_READ = 10
local PREVIEW_WRITE = 10
local PREVIEW_BASH = 10
local PREVIEW_GREP = 15
local PREVIEW_LIST = 20
local PREVIEW_GENERIC = 8

local function fg(code, value)
  return ansi.color(code, tostring(value or ""))
end

local function shorten_path(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  local home = os.getenv("HOME")
  if home and home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function sanitize_output(value)
  local raw = text.strip_ansi(tostring(value or ""))
  raw = raw:gsub("\r\n", "\n")
  if raw:find("\r", 1, true) then
    local out = {}
    local line = {}
    for i = 1, #raw do
      local ch = raw:sub(i, i)
      if ch == "\r" then
        line = {}
      elseif ch == "\n" then
        out[#out + 1] = table.concat(line)
        line = {}
      else
        line[#line + 1] = ch
      end
    end
    out[#out + 1] = table.concat(line)
    raw = table.concat(out, "\n")
  end
  raw = raw:gsub("[%z\001-\008\011\012\014-\031\127]", "")
  return raw:gsub("\t", "   ")
end

local function split_lines(value)
  local cleaned = sanitize_output(value)
  if cleaned == "" then
    return {}
  end
  local out = {}
  for line in (cleaned .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

local function line_count(value)
  return #split_lines(value)
end

local function muted_line(value)
  return fg(FG_MUTED, value)
end

local function dim_line(value)
  return fg(FG_DIM, value)
end

local function warning_line(value)
  return fg(FG_WARNING, value)
end

local function preview_head(value, limit)
  local src = split_lines(value)
  local out = {}
  local n = math.min(#src, limit)
  for i = 1, n do
    out[#out + 1] = muted_line(src[i])
  end
  if #src > limit then
    out[#out + 1] =
      dim_line("... (" .. tostring(#src - limit) .. " more lines, total " .. tostring(#src) .. ")")
  end
  return table.concat(out, "\n")
end

local function preview_tail(value, limit)
  local src = split_lines(value)
  local out = {}
  local first = math.max(1, #src - limit + 1)
  if first > 1 then
    out[#out + 1] = dim_line("... (" .. tostring(first - 1) .. " earlier lines)")
  end
  for i = first, #src do
    out[#out + 1] = muted_line(src[i])
  end
  return table.concat(out, "\n")
end

local function append_warning(lines, message)
  if type(message) == "string" and message ~= "" then
    lines[#lines + 1] = warning_line(message)
  end
end

local function result_warning_lines(result)
  local out = {}
  if result:get("entry_limit_reached") then
    append_warning(out, "Result limit reached; output was clipped.")
  end
  if result:get("truncated") then
    append_warning(out, "Output was truncated.")
  end
  local clipped = tonumber(result:get("lines_clipped"))
  if clipped and clipped > 0 then
    append_warning(out, tostring(clipped) .. " result lines were clipped.")
  end
  local temp_path = result:get("temp_file_path") or result:get("fullOutputPath")
  if type(temp_path) == "string" and temp_path ~= "" then
    append_warning(out, "Full output saved to " .. shorten_path(temp_path))
  end
  return out
end

local function bg_line(bg_code, line)
  line = line or ""
  if not ansi.enabled or not ansi.color_enabled then
    return line
  end
  local bg = ESC .. "[" .. ansi.resolve(bg_code) .. "m"
  line = line:gsub(ESC .. "%[0m", RESET .. bg)
  return bg .. line .. RESET
end

local function split_styled_lines(value)
  local rendered = tostring(value or "")
  if rendered == "" then
    return {}
  end
  if rendered:sub(-1) == "\n" then
    rendered = rendered:sub(1, -2)
  end
  local out = {}
  local cursor = 1
  while true do
    local nl = rendered:find("\n", cursor, true)
    out[#out + 1] = nl and rendered:sub(cursor, nl - 1) or rendered:sub(cursor)
    if not nl then
      break
    end
    cursor = nl + 1
  end
  return out
end

local function box_block(bg_code, value, opts)
  opts = opts or {}
  local lines = split_styled_lines(value)
  if #lines == 0 and not opts.force then
    return ""
  end
  local out = {}
  if opts.top ~= false then
    out[#out + 1] = bg_line(bg_code, "")
  end
  for _, line in ipairs(lines) do
    out[#out + 1] = bg_line(bg_code, " " .. line)
  end
  if opts.bottom ~= false then
    out[#out + 1] = bg_line(bg_code, "")
  end
  return table.concat(out, "\n") .. "\n"
end

local function bg_fn(bg_code)
  return function(line)
    return bg_line(bg_code, line)
  end
end

local function path_arg(input)
  local raw = input and (input.path or input.file_path)
  if type(raw) == "string" and raw ~= "" then
    return raw
  end
  return nil
end

local function format_bash_call(input)
  local command = sanitize_output(input.command or "")
  local display = command ~= "" and command or fg(FG_MUTED, "...")
  local line = fg(FG_TITLE, "$ " .. display)
  local timeout = tonumber(input.timeout)
  if timeout then
    line = line .. fg(FG_MUTED, " (timeout " .. tostring(timeout) .. "s)")
  end
  return line
end

local function format_read_call(input)
  local raw = path_arg(input)
  local path = raw and shorten_path(raw) or nil
  local shown = path and fg(FG_ACCENT, path) or fg(FG_MUTED, "...")
  local offset = tonumber(input.offset)
  local limit = tonumber(input.limit)
  if offset ~= nil or limit ~= nil then
    local start_line = offset or 1
    local end_line = limit and (start_line + limit - 1) or nil
    shown = shown
      .. fg(
        FG_WARNING,
        ":" .. tostring(start_line) .. (end_line and ("-" .. tostring(end_line)) or "")
      )
  end
  return fg(FG_TITLE, "read") .. " " .. shown
end

local function format_write_call(input)
  local raw = path_arg(input)
  local header = fg(FG_TITLE, "write")
    .. " "
    .. (raw and fg(FG_ACCENT, shorten_path(raw)) or fg(FG_MUTED, "..."))
  local body = preview_head(input.content or input.text, PREVIEW_WRITE)
  if body == "" then
    return header
  end
  return header .. "\n\n" .. body
end

local function edit_preview(input, frame)
  if not frame or type(frame.before_text) ~= "string" then
    return nil
  end
  local edits = diff.edits_from_input(input)
  if not edits then
    return nil
  end
  local raw = path_arg(input)
  local preview, err = diff.preview_edits(frame.before_text, edits, raw or frame.path or "")
  if preview then
    frame.preview_diff = preview.diff
    frame.preview_error = nil
    return diff_component.render_diff(preview.diff), M.BG_SUCCESS
  end
  frame.preview_diff = nil
  frame.preview_error = err
  return fg(FG_ERROR, err or "edit preview failed"), M.BG_ERROR
end

local function format_edit_call(input, frame)
  local raw = path_arg(input)
  local header = fg(FG_TITLE, "edit")
    .. " "
    .. (raw and fg(FG_ACCENT, shorten_path(raw)) or fg(FG_MUTED, "..."))
  local preview, bg = edit_preview(input, frame)
  if preview and preview ~= "" then
    return header .. "\n\n" .. preview, bg
  end
  return header, nil
end

local function format_grep_call(input)
  local pattern = sanitize_output(input.pattern or "")
  local raw_path = type(input.path) == "string" and input.path or "."
  local path = shorten_path(raw_path ~= "" and raw_path or ".")
  local out = fg(FG_TITLE, "grep")
    .. " "
    .. (pattern ~= "" and fg(FG_ACCENT, "/" .. pattern .. "/") or fg(FG_MUTED, "//"))
    .. fg(FG_MUTED, " in " .. path)
  if type(input.glob) == "string" and input.glob ~= "" then
    out = out .. fg(FG_MUTED, " (" .. sanitize_output(input.glob) .. ")")
  end
  if tonumber(input.limit) ~= nil then
    out = out .. fg(FG_MUTED, " limit " .. tostring(input.limit))
  end
  return out
end

local function format_find_call(input)
  local pattern = sanitize_output(input.pattern or "")
  local raw_path = type(input.path) == "string" and input.path or "."
  local path = shorten_path(raw_path ~= "" and raw_path or ".")
  local out = fg(FG_TITLE, "find")
    .. " "
    .. (pattern ~= "" and fg(FG_ACCENT, pattern) or fg(FG_MUTED, "..."))
    .. fg(FG_MUTED, " in " .. path)
  if tonumber(input.limit) ~= nil then
    out = out .. fg(FG_MUTED, " (limit " .. tostring(input.limit) .. ")")
  end
  return out
end

local function format_ls_call(input)
  local raw_path = type(input.path) == "string" and input.path or "."
  local path = shorten_path(raw_path ~= "" and raw_path or ".")
  local out = fg(FG_TITLE, "ls") .. " " .. fg(FG_ACCENT, path)
  if tonumber(input.limit) ~= nil then
    out = out .. fg(FG_MUTED, " (limit " .. tostring(input.limit) .. ")")
  end
  return out
end

local function format_lua_call(input)
  local mode = type(input.mode) == "string" and input.mode or "summary"
  local body = mode == "eval"
      and type(input.expression) == "string"
      and fg(FG_ACCENT, input.expression)
    or fg(FG_MUTED, mode)
  return fg(FG_TITLE, "lua") .. " " .. body
end

local function format_generic_call(tool, input)
  local raw = path_arg(input)
  if raw then
    return fg(FG_TITLE, tool or "tool") .. " " .. fg(FG_ACCENT, shorten_path(raw))
  end
  return fg(FG_TITLE, tool or "tool")
end

local function format_call(tool, input, frame)
  if tool == "bash" then
    return format_bash_call(input)
  end
  if tool == "read" then
    return format_read_call(input)
  end
  if tool == "write" then
    return format_write_call(input)
  end
  if tool == "edit" then
    return format_edit_call(input, frame)
  end
  if tool == "grep" then
    return format_grep_call(input)
  end
  if tool == "find" then
    return format_find_call(input)
  end
  if tool == "ls" then
    return format_ls_call(input)
  end
  if tool == "lua" then
    return format_lua_call(input)
  end
  return format_generic_call(tool, input)
end

local function append_preview(lines, value, limit)
  local rendered = preview_head(value, limit)
  if rendered ~= "" then
    lines[#lines + 1] = rendered
  end
end

local function append_tail_preview(lines, value, limit)
  local rendered = preview_tail(value, limit)
  if rendered ~= "" then
    lines[#lines + 1] = rendered
  end
end

local function append_elapsed(lines, frame)
  if not frame or not frame.started_ms then
    return
  end
  local now = type(psi) == "table" and type(psi.time_ms) == "function" and psi.time_ms() or nil
  if type(now) ~= "number" or now < frame.started_ms then
    return
  end
  lines[#lines + 1] = dim_line(string.format("Took %.1fs", (now - frame.started_ms) / 1000))
end

local function format_bash_result(result, frame)
  local lines = {}
  append_tail_preview(lines, result:get("output"), PREVIEW_BASH)
  for _, warning in ipairs(result_warning_lines(result)) do
    lines[#lines + 1] = warning
  end
  append_elapsed(lines, frame)
  if not result.ok and #lines == 0 then
    lines[#lines + 1] = fg(FG_ERROR, "bash failed: " .. tostring(result.error or "unknown error"))
  end
  return table.concat(lines, "\n")
end

local function format_read_result(result)
  if not result.ok then
    return fg(FG_ERROR, "read failed: " .. tostring(result.error or "unknown error"))
  end
  local lines = {}
  append_preview(lines, result:get("text"), PREVIEW_READ)
  for _, warning in ipairs(result_warning_lines(result)) do
    lines[#lines + 1] = warning
  end
  if #lines == 0 then
    lines[#lines + 1] = dim_line("(empty)")
  end
  return table.concat(lines, "\n")
end

local function format_search_result(tool, result)
  if not result.ok then
    return fg(FG_ERROR, tool .. " failed: " .. tostring(result.error or "unknown error"))
  end
  local limit = tool == "grep" and PREVIEW_GREP or PREVIEW_LIST
  local lines = {}
  append_preview(lines, result:get("output"), limit)
  for _, warning in ipairs(result_warning_lines(result)) do
    lines[#lines + 1] = warning
  end
  if #lines == 0 then
    lines[#lines + 1] = dim_line("(no matches)")
  end
  return table.concat(lines, "\n")
end

local function format_write_result(result)
  if not result.ok then
    return fg(FG_ERROR, "write failed: " .. tostring(result.error or "unknown error"))
  end
  return ""
end

local function format_edit_result(result, frame)
  if not result.ok then
    if frame and frame.preview_error and result.error == frame.preview_error then
      return ""
    end
    return fg(FG_ERROR, "edit failed: " .. tostring(result.error or "unknown error"))
  end
  local result_diff = result:get("diff")
  if type(result_diff) == "string" and result_diff ~= "" then
    if frame and frame.preview_diff == result_diff then
      return ""
    end
    return diff_component.render_diff(result_diff)
  end
  local path = result:get("path") or (frame and frame.path)
  local repls = tonumber(result:get("replacements")) or 0
  return dim_line(
    "edited "
      .. shorten_path(path or "")
      .. " ("
      .. tostring(repls)
      .. (repls == 1 and " replacement)" or " replacements)")
  )
end

local function format_lua_result(result)
  if not result.ok then
    return fg(FG_ERROR, "lua failed: " .. tostring(result.error or "unknown error"))
  end
  local value = result:get("result")
  if type(value) ~= "string" or value == "" then
    return dim_line("(no result)")
  end
  return preview_head(value, PREVIEW_GENERIC)
end

local function format_generic_result(tool, result)
  if not result.ok then
    return fg(
      FG_ERROR,
      (tool or "tool") .. " failed: " .. tostring(result.error or "unknown error")
    )
  end
  local value = result:get("output")
  if type(value) ~= "string" or value == "" then
    return dim_line("(ok)")
  end
  return preview_head(value, PREVIEW_GENERIC)
end

local function format_result(tool, result, frame)
  if tool == "bash" then
    return format_bash_result(result, frame)
  end
  if tool == "read" then
    return format_read_result(result)
  end
  if tool == "grep" or tool == "find" or tool == "ls" then
    return format_search_result(tool, result)
  end
  if tool == "write" then
    return format_write_result(result)
  end
  if tool == "edit" then
    return format_edit_result(result, frame)
  end
  if tool == "lua" then
    return format_lua_result(result)
  end
  return format_generic_result(tool, result)
end

local ToolExecution = {}
ToolExecution.__index = ToolExecution

local function component_bg_code(self, call_bg)
  if self.result == nil or self.is_partial then
    return call_bg or M.BG_PENDING
  end
  return self.result.ok and M.BG_SUCCESS or M.BG_ERROR
end

local function update_display(self)
  local call_text, call_bg = format_call(self.tool, self.input, self.frame)
  local preserve_whitespace = self.tool == "edit"
  self.box:set_bg_fn(bg_fn(component_bg_code(self, call_bg)))
  self.call_text:set_wrap_opts({ preserve_whitespace = preserve_whitespace })
  self.result_text:set_wrap_opts({ preserve_whitespace = preserve_whitespace })
  self.call_text:set_text(call_text or "")
  if self.result ~= nil then
    local result_text = format_result(self.tool, self.result, self.frame)
    self.result_text:set_text(
      result_text ~= nil and result_text ~= "" and ("\n" .. result_text) or ""
    )
  else
    self.result_text:set_text("")
  end
  self.generation = (self.generation or 0) + 1
end

function ToolExecution:set_input(input, frame)
  self.input = type(input) == "table" and input or {}
  self.frame = frame or self.frame
  update_display(self)
end

function ToolExecution:set_result(result, is_partial)
  self.result = result
  self.is_partial = not not is_partial
  update_display(self)
end

function ToolExecution:render(width)
  return self.box:render(width)
end

function ToolExecution:invalidate()
  self.generation = (self.generation or 0) + 1
  self.box:invalidate()
end

function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  local obj = setmetatable({
    id = opts.id,
    tool = opts.tool or "tool",
    input = type(opts.input) == "table" and opts.input or {},
    frame = opts.frame,
    result = opts.result,
    is_partial = not not opts.is_partial,
    box = component.box(1, 1, bg_fn(M.BG_PENDING)),
    call_text = component.text("", 0, 0),
    result_text = component.text("", 0, 0),
    generation = 0,
  }, ToolExecution)
  obj.box:add_child(obj.call_text)
  obj.box:add_child(obj.result_text)
  update_display(obj)
  return obj
end

function M.render_call(tool, input, frame)
  local execution = M.new({ tool = tool, input = input, frame = frame })
  return table.concat(execution:render(80), "\n") .. "\n"
end

function M.render_result(tool, result, frame)
  local body = format_result(tool, result, frame)
  local bg = result.ok and M.BG_SUCCESS or M.BG_ERROR
  if body == nil or body == "" then
    if not result.ok then
      return ""
    end
    body = dim_line(tostring(tool or "tool") .. " completed")
  end
  return box_block(bg, body, { top = false, bottom = true })
end

function M.output_line_count(value)
  return line_count(value)
end

return M
