local agent = require("psi.agent")
local ansi = require("psi.ansi")
local commands = require("psi.commands")
local context = require("psi.context")
local markdown = require("psi.markdown")
local prelude = require("psi.prelude")
local render = require("psi.render")
local session = require("psi.session")
local settings = require("psi.settings")
local tui = require("psi.tui")
local tui_layout = require("psi.tui_layout")

local M = {}

local MAX_RENDER_TEXT = 8192

local function safe_decode(text, fallback)
  return prelude.safe_json_decode(text, fallback)
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function is_space_byte(b)
  return b == 32 or b == 9 or b == 10 or b == 11 or b == 12 or b == 13
end

local function trim_trailing_newlines(text)
  text = text or ""
  return (text:gsub("\n+$", ""))
end

local function strip_ansi(text)
  text = text or ""
  text = text:gsub("\27%[[%d;?]*[A-Za-z]", "")
  text = text:gsub("\27[=>]", "")
  text = text:gsub("\27%[%?[%d]+[a-z]", "")
  return text
end

local function limit_text(text)
  text = text or ""
  if #text <= MAX_RENDER_TEXT then
    return text
  end
  return text:sub(1, MAX_RENDER_TEXT) .. "\n\n[output truncated]"
end

local function current_size()
  local size = psi.tui_size()
  local width = math.max(1, tonumber(size and size.width) or 80)
  local height = math.max(1, tonumber(size and size.height) or 24)
  return width, height
end

local function default_input_layout(height)
  height = math.max(12, tonumber(height) or 24)
  return {
    max_rows = math.min(5, math.max(1, height - 5)),
    prefix_first = "> ",
    prefix_rest = "| ",
  }
end

local function refresh_input_layout(state)
  local arg = {
    width = state.width,
    height = state.height,
    busy = state.busy,
    scroll = state.scroll_offset,
    max_rows = settings.get("tui.prompt.max_rows", nil),
  }
  local layout = tui_layout.input_layout_table and tui_layout.input_layout_table(arg)
    or safe_decode(tui_layout.input_layout(psi.json_encode(arg)), {})
  local fallback = default_input_layout(state.height)
  state.input_layout = {
    max_rows = tonumber(layout.max_rows) or fallback.max_rows,
    prefix_first = type(layout.prefix_first) == "string" and layout.prefix_first
      or fallback.prefix_first,
    prefix_rest = type(layout.prefix_rest) == "string" and layout.prefix_rest
      or fallback.prefix_rest,
  }
end

local function input_max_rows(state)
  local max_rows = tonumber(state.input_layout.max_rows) or 5
  max_rows = math.max(1, max_rows)
  max_rows = math.min(max_rows, math.max(1, state.height - 5))
  return max_rows
end

local function input_wrap_width(width, prefix)
  local available = (width - 1) - #(prefix or "")
  if available < 1 then
    available = 1
  end
  return available
end

local function build_input_lines(state)
  local input = state.input or ""
  local input_length = #input
  local lines = {}
  local pos = 0
  local cursor_line = 1
  local cursor_col = 0
  local cursor_found = false

  while true do
    local line_end = pos
    while line_end < input_length and input:byte(line_end + 1) ~= 10 do
      line_end = line_end + 1
    end

    if line_end == pos then
      lines[#lines + 1] = { start = pos, len = 0 }
      if not cursor_found and state.cursor == pos then
        cursor_line = #lines
        cursor_col = 0
        cursor_found = true
      end
    else
      local chunk_start = pos
      while chunk_start < line_end do
        local prefix = (#lines == 0) and state.input_layout.prefix_first
          or state.input_layout.prefix_rest
        local take = math.min(input_wrap_width(state.width, prefix), line_end - chunk_start)
        lines[#lines + 1] = { start = chunk_start, len = take }
        if
          not cursor_found
          and state.cursor >= chunk_start
          and state.cursor <= chunk_start + take
        then
          cursor_line = #lines
          cursor_col = state.cursor - chunk_start
          cursor_found = true
        end
        chunk_start = chunk_start + take
      end
    end

    if line_end == input_length then
      break
    end
    pos = line_end + 1
  end

  if #lines == 0 then
    lines[1] = { start = 0, len = 0 }
  end
  if not cursor_found then
    cursor_line = #lines
    cursor_col = lines[#lines].len
  end
  return lines, cursor_line, cursor_col
end

local function entry_prefixes(entry)
  local kind = entry.kind
  if kind == "user" then
    return "You: ", ""
  end
  if kind == "assistant" then
    return "", ""
  end
  if kind == "tool_call" then
    return "╭─ ", "│  "
  end
  if kind == "tool_result" then
    return "│  ", "│  "
  end
  if kind == "error" then
    return "error: ", ""
  end
  if kind == "compaction" then
    return "— ", ""
  end
  return "", ""
end

local function is_fence_line(text)
  return text:match("^%s*```") ~= nil or text:match("^%s*~~~") ~= nil
end

local function find_break(text, width)
  if #text <= width then
    return #text
  end
  for i = width, 1, -1 do
    local b = text:byte(i)
    if b ~= nil and is_space_byte(b) then
      return i
    end
  end
  return width
end

local function new_state(opts)
  local width, height = current_size()
  local state = {
    opts = opts,
    model = agent.model_descriptor(opts.model),
    entries = {},
    input = "",
    cursor = 0,
    busy = false,
    busy_label = nil,
    busy_started_at = nil,
    running = true,
    scroll_offset = 0,
    status_text = nil,
    status_is_error = false,
    width = width,
    height = height,
    input_layout = default_input_layout(height),
    streaming_assistant_index = nil,
    streaming_thinking_index = nil,
    entries_version = 0,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    dirty = true,
  }
  refresh_input_layout(state)
  return state
end

local function invalidate_render_totals(state)
  state.entries_version = (state.entries_version or 0) + 1
  state.total_cache_width = nil
  state.total_cache_version = nil
  state.total_cache_lines = nil
end

local function set_status(state, text, is_error)
  if type(text) ~= "string" or text == "" then
    state.status_text = nil
    state.status_is_error = false
  else
    state.status_text = text
    state.status_is_error = not not is_error
  end
  state.dirty = true
end

local function add_entry(state, kind, text, title, is_error, tool_call_id)
  local entry = {
    kind = kind,
    text = text or "",
    title = title,
    is_error = not not is_error,
    tool_call_id = tool_call_id,
  }
  state.entries[#state.entries + 1] = entry
  invalidate_render_totals(state)
  state.dirty = true
  return #state.entries
end

local function append_entry_text(state, index, text)
  if index == nil or not state.entries[index] or text == nil then
    return
  end
  local entry = state.entries[index]
  entry.text = (entry.text or "") .. text
  entry.render_cache_width = nil
  entry.render_cache_lines = nil
  invalidate_render_totals(state)
  state.dirty = true
end

local function remove_entry(state, index)
  if index == nil or index < 1 or index > #state.entries then
    return
  end
  table.remove(state.entries, index)
  invalidate_render_totals(state)
  if state.streaming_assistant_index and state.streaming_assistant_index > index then
    state.streaming_assistant_index = state.streaming_assistant_index - 1
  elseif state.streaming_assistant_index == index then
    state.streaming_assistant_index = nil
  end
  if state.streaming_thinking_index and state.streaming_thinking_index > index then
    state.streaming_thinking_index = state.streaming_thinking_index - 1
  elseif state.streaming_thinking_index == index then
    state.streaming_thinking_index = nil
  end
  state.dirty = true
end

local function find_entry_by_tool_id(state, kind, tool_call_id)
  if type(tool_call_id) ~= "string" or tool_call_id == "" then
    return nil
  end
  for i = #state.entries, 1, -1 do
    local entry = state.entries[i]
    if entry.kind == kind and entry.tool_call_id == tool_call_id then
      return i
    end
  end
  return nil
end

local function finish_streaming_assistant(state)
  local index = state.streaming_assistant_index
  if index ~= nil and state.entries[index] and state.entries[index].text == "" then
    remove_entry(state, index)
  end
  state.streaming_assistant_index = nil
end

local function discard_empty_streaming_assistant(state)
  local index = state.streaming_assistant_index
  if index ~= nil and state.entries[index] and state.entries[index].text == "" then
    remove_entry(state, index)
    state.streaming_assistant_index = nil
  end
end

local function render_event_plain(event, payload)
  local ok, text = pcall(render.handle_event, event, payload or {})
  if not ok then
    return nil
  end
  text = limit_text(strip_ansi(text or ""))
  if text == "" then
    return nil
  end
  return text
end

local function format_tool_call(tool_name, input)
  input = type(input) == "table" and input or {}
  if tool_name == "read" or tool_name == "write" or tool_name == "edit" then
    return tool_name .. " " .. tostring(input.path or "")
  end
  if tool_name == "bash" then
    return "$ " .. tostring(input.command or "")
  end
  if tool_name == "grep" or tool_name == "find" then
    return tool_name .. " " .. tostring(input.pattern or "")
  end
  if tool_name == "ls" then
    return "ls " .. tostring(input.path or ".")
  end
  if tool_name == "lua" then
    return "lua " .. tostring(input.mode or "summary")
  end
  return tool_name .. " " .. psi.json_encode(input)
end

local function format_tool_result(tool_name, result)
  result = type(result) == "table" and result or {}
  if result.ok == false then
    return "error: " .. tostring(result.error or "unknown error"), true
  end
  if tool_name == "read" then
    return limit_text(tostring(result.text or "")), false
  end
  if tool_name == "bash" or tool_name == "grep" or tool_name == "find" or tool_name == "ls" then
    return limit_text(tostring(result.output or "")), false
  end
  if tool_name == "write" then
    return string.format(
      "wrote %s (%d bytes)",
      tostring(result.path or ""),
      tonumber(result.bytes_written) or 0
    ),
      false
  end
  if tool_name == "edit" then
    return string.format(
      "edited %s (%d replacements)",
      tostring(result.path or ""),
      tonumber(result.replacements) or 0
    ),
      false
  end
  if tool_name == "lua" then
    return limit_text(tostring(result.result or "")), false
  end
  return limit_text(psi.json_encode(result)), false
end

local function tool_call_text(tool_call_id, tool_name, input)
  local rendered = render_event_plain("tool-call", {
    id = tool_call_id or "",
    tool = tool_name or "tool",
    input = input or {},
  })
  if rendered and rendered ~= "" then
    return rendered
  end
  return format_tool_call(tool_name or "tool", input)
end

local function tool_result_text(tool_call_id, tool_name, result)
  local rendered = render_event_plain("tool-result", {
    id = tool_call_id or "",
    tool = tool_name or "tool",
    result = result or {},
  })
  if rendered and rendered ~= "" then
    return rendered, result ~= nil and result.ok == false
  end
  return format_tool_result(tool_name or "tool", result)
end

local function entry_render_lines(state, entry)
  if entry.render_cache_width == state.width and entry.render_cache_lines ~= nil then
    return entry.render_cache_lines
  end

  local lines = {}
  local first_prefix, rest_prefix = entry_prefixes(entry)
  local trimmed = trim_trailing_newlines(entry.text or "")
  local prefix = first_prefix
  local cursor = 1
  local fence_state = false

  while true do
    local nl = trimmed:find("\n", cursor, true)
    local source_line = nl and trimmed:sub(cursor, nl - 1) or trimmed:sub(cursor)
    local source_line_is_fence = entry.kind == "assistant" and is_fence_line(source_line)
    local line_fence_flag
    if source_line_is_fence then
      line_fence_flag = true
      fence_state = not fence_state
    else
      line_fence_flag = fence_state
    end

    local remaining = source_line
    while true do
      local available = input_wrap_width(state.width, prefix)
      local break_index = find_break(remaining, available)
      local raw = remaining:sub(1, break_index)
      lines[#lines + 1] = {
        kind = entry.kind,
        text = prefix .. raw,
        raw = raw,
        entry = entry,
        in_code_fence = line_fence_flag,
      }
      local next_start = break_index + 1
      while next_start <= #remaining and remaining:byte(next_start) == 32 do
        next_start = next_start + 1
      end
      remaining = remaining:sub(next_start)
      prefix = rest_prefix
      if remaining == "" then
        break
      end
    end
    if not nl then
      break
    end
    cursor = nl + 1
    prefix = rest_prefix
  end

  entry.render_cache_width = state.width
  entry.render_cache_lines = lines
  return lines
end

local function count_entry_lines(state, entry)
  return #entry_render_lines(state, entry)
end

local function total_rendered_lines(state)
  if
    state.total_cache_width == state.width
    and state.total_cache_version == state.entries_version
    and state.total_cache_lines ~= nil
  then
    return state.total_cache_lines
  end
  local total = 0
  for i, entry in ipairs(state.entries) do
    local prev = state.entries[i - 1]
    local next_entry = state.entries[i + 1]
    local same_panel_as_prev = (prev and prev.kind == "tool_call" and entry.kind == "tool_result")
      or (prev and prev.kind == "tool_result" and entry.kind == "tool_result")
    if total > 0 and not same_panel_as_prev then
      total = total + 1
    end
    total = total + count_entry_lines(state, entry)
    if entry.kind == "tool_result" and (not next_entry or next_entry.kind ~= "tool_result") then
      total = total + 1
    end
  end
  state.total_cache_width = state.width
  state.total_cache_version = state.entries_version
  state.total_cache_lines = total
  return total
end

local function scroll_anchor_before(state)
  if state.scroll_offset <= 0 then
    return nil
  end
  return total_rendered_lines(state)
end

local function scroll_anchor_after(state, before_lines)
  if before_lines == nil or state.scroll_offset <= 0 then
    return
  end
  local after_lines = total_rendered_lines(state)
  if after_lines > before_lines then
    state.scroll_offset = state.scroll_offset + (after_lines - before_lines)
  end
end

local function add_session_entry(state, msg)
  local body = safe_decode(msg.data, {})
  if msg.role == "user" then
    add_entry(state, "user", msg.text or "")
    return
  end

  if msg.role == "assistant" then
    local content = body and body.message and body.message.content
    local added_text = false
    if type(content) == "table" then
      for _, block in ipairs(content) do
        if type(block) == "table" then
          if
            block.type == "thinking"
            and type(block.thinking) == "string"
            and block.thinking ~= ""
          then
            add_entry(state, "thinking", block.thinking)
          elseif block.type == "text" and type(block.text) == "string" and block.text ~= "" then
            add_entry(state, "assistant", block.text)
            added_text = true
          elseif block.type == "toolCall" then
            add_entry(
              state,
              "tool_call",
              tool_call_text(block.id, block.name, block.arguments or {}),
              block.name,
              false,
              block.id
            )
          end
        end
      end
    end
    if not added_text and type(msg.text) == "string" and msg.text ~= "" then
      add_entry(state, "assistant", msg.text)
    end
    return
  end

  if msg.role == "tool-result" then
    local message = body and body.message or {}
    local content_text = msg.text or ""
    if type(message.content) == "table" then
      local parts = {}
      for _, block in ipairs(message.content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
          parts[#parts + 1] = block.text
        end
      end
      if #parts > 0 then
        content_text = table.concat(parts)
      end
    end
    local result_text, is_error = tool_result_text(message.toolCallId, message.toolName, {
      ok = not message.isError,
      error = message.isError and content_text or nil,
      output = content_text,
      result = content_text,
    })
    add_entry(state, "tool_result", result_text, message.toolName, is_error, message.toolCallId)
    return
  end

  if msg.role == "compaction-summary" then
    add_entry(state, "compaction", msg.text or "")
    return
  end

  if type(msg.text) == "string" and msg.text ~= "" then
    add_entry(state, "info", msg.text)
  end
end

local function rebuild_from_session(state)
  state.entries = {}
  state.streaming_assistant_index = nil
  state.streaming_thinking_index = nil
  invalidate_render_totals(state)
  for _, msg in ipairs(session.messages()) do
    add_session_entry(state, msg)
  end
  state.scroll_offset = 0
  state.dirty = true
end

local function style_line(line)
  if line.kind == "assistant" then
    return markdown.render_line(line.text, line.in_code_fence)
  end
  if line.kind == "thinking" then
    return ansi.italic(line.text)
  end
  if line.kind == "user" then
    return ansi.bold(ansi.cyan(line.text))
  end
  if line.kind == "tool_call" then
    return ansi.yellow(line.text)
  end
  if line.kind == "tool_result" then
    local title = line.entry.title
    if title == "write" or title == "edit" then
      if line.raw:sub(1, 2) == "+ " then
        return ansi.bold(ansi.green(line.text))
      end
      if line.raw:sub(1, 2) == "- " then
        return ansi.bold(ansi.red(line.text))
      end
      if line.raw:sub(1, 2) == "  " then
        return ansi.dim(line.text)
      end
    end
    if line.entry.is_error then
      return ansi.red(line.text)
    end
    return ansi.green(line.text)
  end
  if line.kind == "panel_close" then
    return ansi.yellow(line.text)
  end
  if line.kind == "error" then
    return ansi.bold(ansi.red(line.text))
  end
  return ansi.dim(line.text)
end

local function build_render_window(state, first_line, count)
  local lines = {}
  local pos = 0
  local last_line = first_line + count - 1

  local function push(line)
    pos = pos + 1
    if pos >= first_line and pos <= last_line then
      lines[pos - first_line + 1] = line
    end
    return pos >= last_line
  end

  for i, entry in ipairs(state.entries) do
    local prev = state.entries[i - 1]
    local next_entry = state.entries[i + 1]
    local same_panel_as_prev = (prev and prev.kind == "tool_call" and entry.kind == "tool_result")
      or (prev and prev.kind == "tool_result" and entry.kind == "tool_result")

    if pos > 0 and not same_panel_as_prev then
      if push({ kind = "blank", text = "" }) then
        return lines
      end
    end

    for _, line in ipairs(entry_render_lines(state, entry)) do
      if push(line) then
        return lines
      end
    end

    if entry.kind == "tool_result" and (not next_entry or next_entry.kind ~= "tool_result") then
      if push({ kind = "panel_close", text = "╰─" }) then
        return lines
      end
    end
  end

  return lines
end

local function layout_rows(state)
  refresh_input_layout(state)
  local input_lines, cursor_line, cursor_col = build_input_lines(state)
  local input_rows = math.max(1, math.min(#input_lines, input_max_rows(state)))
  local input_first_line = 1
  if cursor_line > input_rows then
    input_first_line = cursor_line - input_rows + 1
  end
  if input_first_line + input_rows - 1 > #input_lines then
    input_first_line = #input_lines - input_rows + 1
  end
  local hint_row = state.height - input_rows - 2
  local transcript_start = 2
  local transcript_height = math.max(1, hint_row - transcript_start)

  return {
    input_lines = input_lines,
    cursor_line = cursor_line,
    cursor_col = cursor_col,
    input_rows = input_rows,
    input_first_line = input_first_line,
    transcript_start = transcript_start,
    transcript_height = transcript_height,
    hint_row = hint_row,
    cwd_row = hint_row + 1,
    status_row = hint_row + 2,
    input_start_row = hint_row + 3,
  }
end

local function max_scroll_offset(state)
  local rows = layout_rows(state)
  local total = total_rendered_lines(state)
  return math.max(0, total - rows.transcript_height)
end

local function scroll_by(state, delta)
  state.scroll_offset = clamp(state.scroll_offset + delta, 0, max_scroll_offset(state))
  state.dirty = true
end

local function redraw(state)
  state.width, state.height = current_size()
  local rows = layout_rows(state)
  local total_lines = total_rendered_lines(state)
  local max_scroll = math.max(0, total_lines - rows.transcript_height)
  local status_arg
  local hint_text
  local status_text
  local cwd

  state.scroll_offset = clamp(state.scroll_offset, 0, max_scroll)

  psi.tui_clear()
  psi.tui_draw_line(1, ansi.bold(ansi.cyan("psi coding agent")))

  local first_line = total_lines - rows.transcript_height - state.scroll_offset + 1
  if first_line < 1 then
    first_line = 1
  end
  local transcript_lines = build_render_window(state, first_line, rows.transcript_height)
  for i = 0, rows.transcript_height - 1 do
    local line = transcript_lines[i + 1]
    psi.tui_draw_line(rows.transcript_start + i, line and style_line(line) or "")
  end

  status_arg = {
    model = state.model and state.model.id or state.opts.model,
    provider = state.model and state.model.provider or nil,
    context_window = state.model and state.model.context_window or nil,
    busy = state.busy,
    busy_label = state.busy_label,
    elapsed_seconds = state.busy_started_at and (os.time() - state.busy_started_at) or 0,
    busy_phase = state.busy_started_at and (((os.time() - state.busy_started_at) % 3) + 1) or 0,
    scroll = state.scroll_offset,
  }

  if state.status_text ~= nil then
    hint_text = state.status_is_error and ansi.bold(ansi.red(state.status_text))
      or ansi.dim(state.status_text)
  else
    hint_text = ansi.dim(tui.footer_hint(status_arg) or "")
  end
  psi.tui_draw_line(rows.hint_row, hint_text)

  cwd = psi.cwd() or "."
  psi.tui_draw_line(rows.cwd_row, ansi.dim(cwd))

  status_text = tui.status_line(status_arg) or ""
  psi.tui_draw_line(rows.status_row, ansi.dim(status_text))

  for i = 0, rows.input_rows - 1 do
    local line_index = rows.input_first_line + i
    local line = rows.input_lines[line_index]
    local prefix = line_index == 1 and state.input_layout.prefix_first
      or state.input_layout.prefix_rest
    local text = prefix
    if line ~= nil then
      text = text .. state.input:sub(line.start + 1, line.start + line.len)
    end
    psi.tui_draw_line(rows.input_start_row + i, ansi.bold(ansi.cyan(text)))
  end

  local visible_cursor_line = rows.cursor_line - rows.input_first_line + 1
  local cursor_prefix = rows.cursor_line == 1 and state.input_layout.prefix_first
    or state.input_layout.prefix_rest
  local cursor_row = rows.input_start_row + visible_cursor_line - 1
  local cursor_col = #cursor_prefix + rows.cursor_col + 1
  cursor_row = clamp(cursor_row, rows.input_start_row, state.height)
  cursor_col = clamp(cursor_col, 1, math.max(1, state.width - 1))
  psi.tui_set_cursor(cursor_row, cursor_col, true)
  psi.tui_refresh()
  state.dirty = false
end

local function byte_at(text, pos)
  if pos < 0 or pos >= #text then
    return nil
  end
  return text:byte(pos + 1)
end

local function insert_text(state, text)
  state.input = state.input:sub(1, state.cursor) .. text .. state.input:sub(state.cursor + 1)
  state.cursor = state.cursor + #text
  state.dirty = true
end

local function delete_backward(state)
  if state.cursor == 0 or #state.input == 0 then
    return
  end
  state.input = state.input:sub(1, state.cursor - 1) .. state.input:sub(state.cursor + 1)
  state.cursor = state.cursor - 1
  state.dirty = true
end

local function delete_forward(state)
  if state.cursor >= #state.input then
    return
  end
  state.input = state.input:sub(1, state.cursor) .. state.input:sub(state.cursor + 2)
  state.dirty = true
end

local function delete_word_backward(state)
  if state.cursor == 0 then
    return
  end
  local start = state.cursor
  while start > 0 do
    local b = byte_at(state.input, start - 1)
    if b == nil or not is_space_byte(b) then
      break
    end
    start = start - 1
  end
  while start > 0 do
    local b = byte_at(state.input, start - 1)
    if b == nil or is_space_byte(b) then
      break
    end
    start = start - 1
  end
  state.input = state.input:sub(1, start) .. state.input:sub(state.cursor + 1)
  state.cursor = start
  state.dirty = true
end

local function delete_word_forward(state)
  if state.cursor >= #state.input then
    return
  end
  local finish = state.cursor
  while finish < #state.input do
    local b = byte_at(state.input, finish)
    if b == nil or not is_space_byte(b) then
      break
    end
    finish = finish + 1
  end
  while finish < #state.input do
    local b = byte_at(state.input, finish)
    if b == nil or is_space_byte(b) then
      break
    end
    finish = finish + 1
  end
  state.input = state.input:sub(1, state.cursor) .. state.input:sub(finish + 1)
  state.dirty = true
end

local function move_word_backward(state)
  local pos = state.cursor
  while pos > 0 do
    local b = byte_at(state.input, pos - 1)
    if b == nil or not is_space_byte(b) then
      break
    end
    pos = pos - 1
  end
  while pos > 0 do
    local b = byte_at(state.input, pos - 1)
    if b == nil or is_space_byte(b) then
      break
    end
    pos = pos - 1
  end
  state.cursor = pos
  state.dirty = true
end

local function move_word_forward(state)
  local pos = state.cursor
  while pos < #state.input do
    local b = byte_at(state.input, pos)
    if b == nil or not is_space_byte(b) then
      break
    end
    pos = pos + 1
  end
  while pos < #state.input do
    local b = byte_at(state.input, pos)
    if b == nil or is_space_byte(b) then
      break
    end
    pos = pos + 1
  end
  state.cursor = pos
  state.dirty = true
end

local function kill_to_end(state)
  state.input = state.input:sub(1, state.cursor)
  state.dirty = true
end

local function kill_to_start(state)
  if state.cursor == 0 then
    return
  end
  state.input = state.input:sub(state.cursor + 1)
  state.cursor = 0
  state.dirty = true
end

local function observer_text_delta(state, text)
  if type(text) ~= "string" or text == "" then
    return
  end
  local before = scroll_anchor_before(state)
  state.streaming_thinking_index = nil
  if state.streaming_assistant_index == nil then
    state.streaming_assistant_index = add_entry(state, "assistant", "")
  end
  append_entry_text(state, state.streaming_assistant_index, text)
  scroll_anchor_after(state, before)
end

local function observer_thinking_delta(state, text)
  if type(text) ~= "string" or text == "" then
    return
  end
  local before = scroll_anchor_before(state)
  discard_empty_streaming_assistant(state)
  if state.streaming_thinking_index == nil then
    state.streaming_thinking_index = add_entry(state, "thinking", "")
  end
  append_entry_text(state, state.streaming_thinking_index, text)
  scroll_anchor_after(state, before)
end

local function observer_tool_call(state, tool_call_id, tool_name, input_json)
  local before = scroll_anchor_before(state)
  local input = safe_decode(input_json, {})
  finish_streaming_assistant(state)
  state.streaming_thinking_index = nil
  add_entry(
    state,
    "tool_call",
    tool_call_text(tool_call_id, tool_name, input),
    tool_name,
    false,
    tool_call_id
  )
  add_entry(state, "tool_result", "", tool_name, false, tool_call_id)
  scroll_anchor_after(state, before)
end

local function observer_tool_progress(state, tool_call_id, chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return
  end
  local before = scroll_anchor_before(state)
  local index = find_entry_by_tool_id(state, "tool_result", tool_call_id)
  if index == nil then
    index = add_entry(state, "tool_result", "", nil, false, tool_call_id)
  end
  append_entry_text(state, index, chunk)
  scroll_anchor_after(state, before)
end

local function observer_tool_result(state, tool_call_id, tool_name, output_json)
  local before = scroll_anchor_before(state)
  local result = safe_decode(output_json, nil)
  local text, is_error = tool_result_text(tool_call_id, tool_name, result)
  local index = find_entry_by_tool_id(state, "tool_result", tool_call_id)

  if index ~= nil and state.entries[index] then
    local entry = state.entries[index]
    entry.title = tool_name
    entry.text = text or ""
    entry.is_error = not not is_error
    entry.render_cache_width = nil
    entry.render_cache_lines = nil
  else
    add_entry(state, "tool_result", text or "", tool_name, is_error, tool_call_id)
  end

  scroll_anchor_after(state, before)
end

local function fire_turn_event(state, event, payload)
  local rendered = render_event_plain(event, payload)
  if rendered ~= nil and rendered ~= "" then
    add_entry(state, "info", rendered)
  end
end

local function after_turn_payload(reply, assistant_streamed)
  return {
    text = reply or "",
    ["assistant-streamed"] = not not assistant_streamed,
  }
end

local function run_turn(state, line)
  local assistant_streamed = false
  local observer = {
    on_assistant_text_delta = function(text)
      observer_text_delta(state, text)
      if type(text) == "string" and text ~= "" then
        assistant_streamed = true
      end
    end,
    on_tool_call = function(id, name, input_json)
      -- Match pi-mono's event ordering: assistant message_end is
      -- delivered before tool_execution_start. Without this boundary,
      -- text streamed after the tool result can append to the same
      -- live assistant entry that emitted the tool call.
      finish_streaming_assistant(state)
      state.streaming_thinking_index = nil
      observer_tool_call(state, id, name, input_json)
    end,
    on_tool_result = function(id, name, output_json)
      observer_tool_result(state, id, name, output_json)
    end,
    on_thinking_delta = function(text)
      observer_thinking_delta(state, text)
    end,
  }

  fire_turn_event(state, "before-turn", { text = line or "" })
  local ran, ok, reply = xpcall(function()
    return agent.run_turn({
      user_text = line or "",
      model = state.opts.model,
      max_tokens = state.opts.max_tokens,
      observer = observer,
      abort_check = psi.is_aborted,
    })
  end, debug.traceback)

  finish_streaming_assistant(state)
  state.streaming_thinking_index = nil

  if not ran then
    add_entry(state, "error", reply or "agent turn failed")
    set_status(state, "agent turn failed", true)
    fire_turn_event(state, "after-turn", after_turn_payload("", false))
    session.save()
    return false
  end

  fire_turn_event(state, "after-turn", after_turn_payload(reply, assistant_streamed))

  if not ok then
    if reply == "aborted" then
      set_status(state, "aborted", false)
    else
      add_entry(state, "error", reply ~= "" and reply or "provider request failed")
      set_status(state, "agent turn failed", true)
    end
    session.save()
    return false
  end

  local saved, err = session.save()
  if not saved then
    set_status(state, "failed to save session file: " .. tostring(err), true)
  else
    set_status(state, "", false)
  end
  return true
end

local function run_compact(state, keep_recent)
  state.busy = true
  state.busy_label = "Compacting"
  state.busy_started_at = os.time()
  psi.abort_reset()
  set_status(state, "", false)
  redraw(state)

  local ran, ok, summary = xpcall(function()
    return agent.run_compact({
      keep_recent = keep_recent,
      model = state.opts.model,
      max_tokens = state.opts.max_tokens,
    })
  end, debug.traceback)

  if ran and ok then
    local saved, err = session.save()
    if not saved then
      set_status(state, "failed to save compacted session: " .. tostring(err), true)
    else
      rebuild_from_session(state)
      set_status(state, "session compacted", false)
    end
  else
    set_status(state, "failed to compact session", true)
    if not ran then
      add_entry(state, "error", summary or "compaction failed")
    end
  end

  state.busy = false
  state.busy_label = nil
  state.busy_started_at = nil
  state.dirty = true
  redraw(state)
end

local function handle_command(state, line)
  if line == "/quit" or line == "/q" or line == ":quit" or line == ":q" then
    state.running = false
    return true
  end

  local action = commands.handle(line)
  if action == nil then
    set_status(state, "unknown command", true)
    return true
  end

  if action.kind == "print" then
    rebuild_from_session(state)
    if type(action.payload) == "string" and action.payload ~= "" then
      add_entry(state, "info", action.payload)
    end
    set_status(state, "", false)
    return true
  end

  if action.kind == "compact" then
    run_compact(state, tonumber(action.payload) or 12)
    return true
  end

  if action.kind == "expand" then
    return false, action.payload or ""
  end

  if action.kind == "quit" then
    state.running = false
    return true
  end

  if action.kind == "set-model" then
    agent.set_model(action.payload)
    state.opts.model = action.payload
    state.model = agent.model_descriptor(action.payload)
    add_entry(state, "info", "model set to " .. tostring(action.payload))
    set_status(state, "", false)
    return true
  end

  if action.kind == "resume" then
    local ok, err = session.load(action.payload)
    if not ok then
      set_status(state, "resume failed: " .. tostring(err), true)
      return true
    end
    state.opts.session_file = action.payload
    context.reset_usage()
    rebuild_from_session(state)
    add_entry(
      state,
      "info",
      "resumed "
        .. tostring(action.payload)
        .. " ("
        .. tostring(psi.session_message_count())
        .. " messages)"
    )
    set_status(state, "", false)
    return true
  end

  if action.kind == "name" then
    session.set_display_name(action.payload)
    if state.opts.session_file and state.opts.session_file ~= "" then
      session.save()
    end
    add_entry(state, "info", "name set to '" .. tostring(action.payload) .. "'")
    set_status(state, "", false)
    return true
  end

  set_status(state, "unknown command", true)
  return true
end

local function submit(state)
  if state.busy or state.input == "" then
    return
  end

  local line = state.input
  state.input = ""
  state.cursor = 0

  if line:sub(1, 1) == "/" then
    local handled, expanded = handle_command(state, line)
    if handled then
      return
    end
    line = expanded or ""
  end

  add_entry(state, "user", line)
  state.streaming_assistant_index = add_entry(state, "assistant", "")
  state.scroll_offset = 0
  state.busy = true
  state.busy_label = "Working"
  state.busy_started_at = os.time()
  psi.abort_reset()
  set_status(state, "", false)
  redraw(state)
  run_turn(state, line)
  state.busy = false
  state.busy_label = nil
  state.busy_started_at = nil
  state.dirty = true
end

local function apply_action(state, action, arg)
  if action == nil or action == "" or action == "noop" then
    return
  end
  if action == "insert" then
    insert_text(state, arg or "")
    return
  end
  if action == "submit" then
    submit(state)
    return
  end
  if action == "delete-backward" then
    delete_backward(state)
    return
  end
  if action == "delete-forward" then
    delete_forward(state)
    return
  end
  if action == "delete-word-backward" then
    delete_word_backward(state)
    return
  end
  if action == "delete-word-forward" then
    delete_word_forward(state)
    return
  end
  if action == "move-left" then
    if state.cursor > 0 then
      state.cursor = state.cursor - 1
    end
    state.dirty = true
    return
  end
  if action == "move-right" then
    if state.cursor < #state.input then
      state.cursor = state.cursor + 1
    end
    state.dirty = true
    return
  end
  if action == "move-home" then
    state.cursor = 0
    state.dirty = true
    return
  end
  if action == "move-end" then
    state.cursor = #state.input
    state.dirty = true
    return
  end
  if action == "move-word-left" then
    move_word_backward(state)
    return
  end
  if action == "move-word-right" then
    move_word_forward(state)
    return
  end
  if action == "kill-end" then
    kill_to_end(state)
    return
  end
  if action == "kill-start" then
    kill_to_start(state)
    return
  end
  if action == "scroll" then
    if arg == "page-up" then
      scroll_by(state, math.max(4, math.floor(state.height / 2)))
    elseif arg == "page-down" then
      scroll_by(state, -math.max(4, math.floor(state.height / 2)))
    elseif arg == "line-up" then
      scroll_by(state, 1)
    elseif arg == "line-down" then
      scroll_by(state, -1)
    end
    return
  end
  if action == "redraw" then
    state.dirty = true
    return
  end
  if action == "abort" then
    psi.abort_trigger()
    set_status(state, "aborting...", false)
    return
  end
  if action == "quit" then
    state.running = false
    return
  end
  if action == "suspend" then
    psi.tui_suspend()
    state.dirty = true
  end
end

local function handle_key_event(state, event)
  if type(event) ~= "table" or type(event.key) ~= "string" then
    return
  end
  if event.key == "resize" then
    state.dirty = true
    return
  end
  local result = tui.handle_key({
    key = event.key,
    busy = state.busy,
    input_length = #state.input,
    cursor = state.cursor,
    scroll = state.scroll_offset,
    text = event.text or "",
  })
  if result == nil then
    return
  end
  apply_action(state, result.action, result.arg)
end

local function tick(state)
  while true do
    local event = psi.tui_poll_key(0)
    if event == nil then
      break
    end
    handle_key_event(state, event)
  end
  if state.busy then
    state.dirty = true
  end
  if state.dirty then
    redraw(state)
  end
end

local function bootstrap_session(opts)
  if opts.session_file and opts.session_file ~= "" then
    local ok, err = session.load(opts.session_file)
    if not ok then
      return false, err
    end
    return true
  end

  session.ensure_default_path()
  session.announce_start()
  return true
end

function M.run(opts)
  local ok, err = bootstrap_session(opts)
  if not ok then
    io.stderr:write("failed to load session file: " .. tostring(err) .. "\n")
    return false
  end

  local state = new_state(opts)
  rebuild_from_session(state)

  local success, runtime_err = xpcall(function()
    psi.tui_set_tick_handler(function()
      tick(state)
    end)
    psi.tui_set_tool_progress_handler(function(tool_call_id, chunk)
      observer_tool_progress(state, tool_call_id, chunk)
    end)
    redraw(state)

    while state.running do
      local event = psi.tui_poll_key(-1)
      if event ~= nil then
        handle_key_event(state, event)
      end
      if state.dirty then
        redraw(state)
      end
    end
  end, debug.traceback)

  psi.tui_set_tick_handler(nil)
  psi.tui_set_tool_progress_handler(nil)
  session.announce_shutdown()

  if not success then
    io.stderr:write("TUI runtime error: " .. tostring(runtime_err) .. "\n")
    return false
  end
  return true
end

function M._debug_input_lines(input, cursor, width, prefix_first, prefix_rest)
  local state = {
    input = input or "",
    cursor = tonumber(cursor) or #(input or ""),
    width = tonumber(width) or 80,
    height = 24,
    input_layout = {
      max_rows = 5,
      prefix_first = prefix_first or "> ",
      prefix_rest = prefix_rest or "| ",
    },
  }
  local lines, cursor_line, cursor_col = build_input_lines(state)
  local out = {}
  for i, line in ipairs(lines) do
    local prefix = i == 1 and state.input_layout.prefix_first or state.input_layout.prefix_rest
    out[i] = prefix .. state.input:sub(line.start + 1, line.start + line.len)
  end
  return {
    lines = out,
    cursor_line = cursor_line,
    cursor_col = cursor_col,
  }
end

function M._debug_bootstrap_session(opts)
  return bootstrap_session(opts or {})
end

function M._debug_after_turn_payload(reply, assistant_streamed)
  return after_turn_payload(reply, assistant_streamed)
end

function M._debug_resolve_input_layout(width, height, busy, scroll)
  local state = {
    width = tonumber(width) or 80,
    height = tonumber(height) or 24,
    busy = not not busy,
    scroll_offset = tonumber(scroll) or 0,
  }
  refresh_input_layout(state)
  return state.input_layout
end

return M
