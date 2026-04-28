local agent = require("psi.agent")
local ansi = require("psi.ansi")
local commands = require("psi.commands")
local context = require("psi.context")
local markdown = require("psi.markdown")
local prelude = require("psi.prelude")
local render = require("psi.render")
local sched = require("psi.sched")
local session = require("psi.session")
local settings = require("psi.settings")
local tui = require("psi.tui")
local tui_layout = require("psi.tui_layout")

local M = {}

local MAX_RENDER_TEXT = 8192
local MAX_RENDER_TRUNCATION_SUFFIX = "\n\n[output truncated]"

local DEFAULT_WIDTH = 80
local DEFAULT_HEIGHT = 24
local MIN_SIZE = 1
local MIN_HEIGHT = 12
local PROMPT_RESERVED_ROWS = 6
local FRAME_WIDTH_MARGIN = 1

local BYTE_TAB = 9
local BYTE_LF = 10
local BYTE_VTAB = 11
local BYTE_FF = 12
local BYTE_CR = 13
local BYTE_ESC = 27
local BYTE_SPACE = 32
local BYTE_BEL = 7
local BYTE_BACKSLASH = 92
local BYTE_DEL = 127
local BYTE_CSI_FINAL_START = 64
local BYTE_CSI_FINAL_END = 126
local CHAR_CSI = "["
local CHAR_DCS = "P"
local CHAR_OSC = "]"
local CHAR_PM = "^"
local CHAR_APC = "_"
local CHAR_ST = "\\"
local UTF8_CONTINUATION_MASK = 0xC0
local UTF8_CONTINUATION_TAG = 0x80

local SETTING_PROMPT_MAX_ROWS = "tui.prompt.max_rows"

local ANSI_PATTERN_CSI = "\27%[[%d;?]*[A-Za-z]"
local ANSI_PATTERN_KEYPAD = "\27[=>]"
local ANSI_PATTERN_PRIVATE_MODE = "\27%[%?[%d]+[a-z]"

local EMPTY = ""
local NEWLINE = "\n"
local FALLBACK_PROMPT_PREFIX_FIRST = "> "
local FALLBACK_PROMPT_PREFIX_REST = "| "

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
  return b == BYTE_SPACE
    or b == BYTE_TAB
    or b == BYTE_LF
    or b == BYTE_VTAB
    or b == BYTE_FF
    or b == BYTE_CR
end

local function trim_trailing_newlines(text)
  text = text or EMPTY
  return (text:gsub(NEWLINE .. "+$", EMPTY))
end

local function strip_ansi(text)
  text = text or EMPTY
  text = text:gsub(ANSI_PATTERN_CSI, EMPTY)
  text = text:gsub(ANSI_PATTERN_KEYPAD, EMPTY)
  text = text:gsub(ANSI_PATTERN_PRIVATE_MODE, EMPTY)
  return text
end

local function find_string_terminator(text, start)
  local i = start
  while i <= #text do
    local byte = text:byte(i)
    if byte == BYTE_BEL then
      return i + 1
    end
    if byte == BYTE_ESC and text:byte(i + 1) == BYTE_BACKSLASH then
      return i + 2
    end
    i = i + 1
  end
  return #text + 1
end

local function find_csi_terminator(text, start)
  local i = start
  while i <= #text do
    local byte = text:byte(i)
    if byte >= BYTE_CSI_FINAL_START and byte <= BYTE_CSI_FINAL_END then
      return i + 1
    end
    i = i + 1
  end
  return #text + 1
end

local function sanitize_terminal_text(text, preserve_newlines)
  text = tostring(text or EMPTY)
  local out = {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local next_char = text:sub(i + 1, i + 1)
    if byte == BYTE_ESC then
      if next_char == CHAR_CSI then
        i = find_csi_terminator(text, i + 2)
      elseif
        next_char == CHAR_OSC
        or next_char == CHAR_DCS
        or next_char == CHAR_PM
        or next_char == CHAR_APC
      then
        i = find_string_terminator(text, i + 2)
      elseif next_char == CHAR_ST then
        i = i + 2
      else
        i = i + 2
      end
    elseif byte == BYTE_LF and preserve_newlines then
      out[#out + 1] = NEWLINE
      i = i + 1
    elseif byte < BYTE_SPACE or byte == BYTE_DEL then
      out[#out + 1] = " "
      i = i + 1
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function display_width(text)
  local width = 0
  local i = 1
  text = strip_ansi(tostring(text or ""))
  while i <= #text do
    local ch = text:byte(i)
    if ch == BYTE_ESC and text:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #text and text:sub(j, j) ~= "m" do
        j = j + 1
      end
      i = j < #text and (j + 1) or (#text + 1)
    else
      if (ch & UTF8_CONTINUATION_MASK) ~= UTF8_CONTINUATION_TAG then
        width = width + 1
      end
      i = i + 1
    end
  end
  return width
end

local function limit_text(text)
  text = text or EMPTY
  if #text <= MAX_RENDER_TEXT then
    return text
  end
  return text:sub(1, MAX_RENDER_TEXT) .. MAX_RENDER_TRUNCATION_SUFFIX
end

local function limit_live_tool_progress_text(text)
  text = text or EMPTY
  if #text <= MAX_RENDER_TEXT then
    return text
  end
  local prefix = "[earlier output truncated]\n\n"
  local keep = math.max(0, MAX_RENDER_TEXT - #prefix)
  return prefix .. text:sub(#text - keep + 1)
end

local function current_size()
  local size = psi.tui_size()
  local width = math.max(MIN_SIZE, tonumber(size and size.width) or DEFAULT_WIDTH)
  local height = math.max(MIN_SIZE, tonumber(size and size.height) or DEFAULT_HEIGHT)
  return width, height
end

local function env_bool(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return nil
  end
  value = value:lower()
  if value == "0" or value == "false" or value == "off" or value == "no" then
    return false
  end
  if value == "1" or value == "true" or value == "on" or value == "yes" then
    return true
  end
  return nil
end

local function detect_tui_capabilities()
  local info = type(psi.runtime_info) == "function" and psi.runtime_info() or {}
  local term = os.getenv("TERM") or ""
  local ansi_ok = info.ansi ~= false and term ~= "" and term ~= "dumb"
  local color_ok = ansi_ok and info.color ~= false
  local force_ansi = env_bool("PSI_ANSI")
  local force_color = env_bool("PSI_COLOR")

  if force_ansi ~= nil then
    ansi_ok = force_ansi and info.ansi ~= false
  end
  if os.getenv("NO_COLOR") ~= nil and os.getenv("NO_COLOR") ~= "" then
    color_ok = false
  end
  if force_color ~= nil then
    color_ok = force_color and ansi_ok and info.color ~= false
  end

  local raw_ansi_ok = ansi_ok and type(psi.tui_draw_raw_line) == "function"

  return {
    ansi = ansi_ok,
    color = color_ok,
    raw_ansi = raw_ansi_ok,
    term = term,
  }
end

local function default_input_layout(height)
  height = math.max(MIN_HEIGHT, tonumber(height) or DEFAULT_HEIGHT)
  return {
    max_rows = math.max(MIN_SIZE, height - PROMPT_RESERVED_ROWS),
    prefix_first = FALLBACK_PROMPT_PREFIX_FIRST,
    prefix_rest = FALLBACK_PROMPT_PREFIX_REST,
  }
end

local function refresh_input_layout(state)
  local arg = {
    width = state.width,
    height = state.height,
    busy = state.busy,
    scroll = state.scroll_offset,
    max_rows = settings.get(SETTING_PROMPT_MAX_ROWS, nil),
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
  max_rows = math.max(MIN_SIZE, max_rows)
  max_rows = math.min(max_rows, math.max(MIN_SIZE, state.height - PROMPT_RESERVED_ROWS))
  return max_rows
end

local function input_wrap_width(width, prefix)
  local available = (width - FRAME_WIDTH_MARGIN) - display_width(prefix)
  if available < MIN_SIZE then
    available = MIN_SIZE
  end
  return available
end

local function build_input_lines(state)
  local input = state.input or EMPTY
  local input_length = #input
  local lines = {}
  local pos = 0
  local cursor_line = 1
  local cursor_col = 0
  local cursor_found = false

  while true do
    local line_end = pos
    while line_end < input_length and input:byte(line_end + 1) ~= BYTE_LF do
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
          cursor_col = display_width(input:sub(chunk_start + 1, state.cursor))
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
    cursor_col =
      display_width(input:sub(lines[#lines].start + 1, lines[#lines].start + lines[#lines].len))
  end
  return lines, cursor_line, cursor_col
end

local function entry_prefixes(entry)
  local kind = entry.kind
  if kind == "user" then
    return "You: ", EMPTY
  end
  if kind == "assistant" then
    return EMPTY, EMPTY
  end
  if kind == "tool_call" then
    return "╭─ ", "│  "
  end
  if kind == "tool_result" then
    return "│  ", "│  "
  end
  if kind == "error" then
    return "error: ", EMPTY
  end
  if kind == "compaction" then
    return "— ", EMPTY
  end
  return EMPTY, EMPTY
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

local clear_selection
local set_status

local function new_state(opts)
  local width, height = current_size()
  local caps = detect_tui_capabilities()
  ansi.enabled = caps.ansi
  ansi.color_enabled = caps.color
  local state = {
    opts = opts,
    model = agent.model_descriptor(opts.model),
    entries = {},
    input = "",
    cursor = 0,
    editor_mode = "insert",
    selection_anchor = nil,
    selection_kind = nil,
    clipboard = "",
    pending_key = nil,
    block_edit = nil,
    force_physical_clear = false,
    busy = false,
    busy_label = nil,
    busy_phase = 0,
    busy_tick = 0,
    busy_started_at = nil,
    busy_kind = nil,
    running = true,
    scroll_offset = 0,
    status_text = nil,
    status_is_error = false,
    show_thinking = tui.show_thinking() == "1",
    width = width,
    height = height,
    input_layout = default_input_layout(height),
    tui_caps = caps,
    streaming_assistant_index = nil,
    streaming_thinking_index = nil,
    queue_nav_index = nil,
    entries_version = 0,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    dirty = true,
  }
  refresh_input_layout(state)
  if tui.run_startup_hooks then
    tui.run_startup_hooks({ opts = opts, state = state })
  end
  return state
end

local function invalidate_render_totals(state)
  state.entries_version = (state.entries_version or 0) + 1
  state.total_cache_width = nil
  state.total_cache_version = nil
  state.total_cache_lines = nil
end

function set_status(state, text, is_error)
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

local function set_entry_text(state, index, text)
  if index == nil or not state.entries[index] then
    return
  end
  local entry = state.entries[index]
  entry.text = text or ""
  entry.render_cache_width = nil
  entry.render_cache_lines = nil
  invalidate_render_totals(state)
  state.dirty = true
end

local function append_entry_text(state, index, text)
  if index == nil or not state.entries[index] or text == nil then
    return
  end
  local entry = state.entries[index]
  set_entry_text(state, index, (entry.text or "") .. text)
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

  if entry.kind == "ansi" then
    local lines = {}
    local text = trim_trailing_newlines(entry.text or "")
    local cursor = 1
    while true do
      local nl = text:find("\n", cursor, true)
      local source_line = nl and text:sub(cursor, nl - 1) or text:sub(cursor)
      lines[#lines + 1] = {
        kind = entry.kind,
        text = source_line,
        raw = source_line,
        entry = entry,
      }
      if not nl then
        break
      end
      cursor = nl + 1
    end
    entry.render_cache_width = state.width
    entry.render_cache_lines = lines
    return lines
  end

  local lines = {}
  local first_prefix, rest_prefix = entry_prefixes(entry)
  local trimmed = sanitize_terminal_text(trim_trailing_newlines(entry.text or ""), true)
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
            state.show_thinking
            and block.type == "thinking"
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
  state.show_thinking = tui.show_thinking() == "1"
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
    return ansi.dim(line.text)
  end
  if line.kind == "user" then
    return ansi.bold(ansi.cyan(line.text))
  end
  if line.kind == "tool_call" then
    return ansi.yellow(line.text)
  end
  if line.kind == "btw" then
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
  if line.kind == "ansi" then
    return line.text
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
  local footer_row = state.height
  local input_box_rows = input_rows + 2
  local input_start_row = footer_row - input_box_rows
  local status_visible = state.busy or state.status_text ~= nil
  local status_row = status_visible and (input_start_row - 1) or nil
  local transcript_start = 2
  local transcript_end = status_visible and (status_row - 1) or (input_start_row - 1)
  local transcript_height = math.max(1, transcript_end - transcript_start + 1)

  return {
    header_row = 1,
    input_lines = input_lines,
    cursor_line = cursor_line,
    cursor_col = cursor_col,
    input_rows = input_rows,
    input_box_rows = input_box_rows,
    input_first_line = input_first_line,
    transcript_start = transcript_start,
    transcript_height = transcript_height,
    status_visible = status_visible,
    status_row = status_row,
    footer_row = footer_row,
    input_start_row = input_start_row,
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

local function tui_chrome_color(code, text)
  if not ansi.enabled or not ansi.color_enabled then
    return text
  end
  return string.char(27) .. "[" .. code .. "m" .. text .. string.char(27) .. "[0m"
end

local function style_input_prefix(prefix, is_first)
  local bg = tonumber(settings.get("tui.input.background", 238)) or 238
  if is_first then
    local chip_bg = tonumber(settings.get("tui.input.prefix_background", 245)) or 245
    return tui_chrome_color("1;38;5;16;48;5;" .. tostring(chip_bg), prefix)
  end
  return tui_chrome_color("38;5;242;48;5;" .. tostring(bg), prefix)
end

local function style_input_text(text)
  local bg = tonumber(settings.get("tui.input.background", 238)) or 238
  local fg = tonumber(settings.get("tui.input.foreground", 253)) or 253
  return tui_chrome_color("38;5;" .. tostring(fg) .. ";48;5;" .. tostring(bg), text)
end

local function style_input_cursor(text)
  return tui_chrome_color("1;38;5;16;48;5;253", text == "" and " " or text)
end

local function style_input_fill(width, slot)
  local default_bg = tonumber(settings.get("tui.input.background", 238)) or 238
  local setting = slot == "rail" and "tui.input.rail_background" or "tui.input.background"
  local bg = tonumber(settings.get(setting, default_bg)) or default_bg
  return tui_chrome_color("48;5;" .. tostring(bg), string.rep(" ", math.max(0, width)))
end

local function input_box_line(content, width)
  content = content or ""
  width = math.max(1, tonumber(width) or 1)
  return content .. style_input_fill(width - display_width(content), "body")
end

local function style_screen_fill(width)
  return string.rep(" ", math.max(0, width))
end

local function padded_frame_text(text, width)
  text = text or ""
  return text .. style_screen_fill(width - display_width(text))
end

local function frame_line(row, text, width)
  return "\27[" .. tostring(row) .. ";1H" .. padded_frame_text(text, width)
end

local render_input_text
local render_input_text_with_cursor
local input_line_selected

local function redraw(state)
  state.width, state.height = current_size()
  local rows = layout_rows(state)
  local total_lines = total_rendered_lines(state)
  local max_scroll = math.max(0, total_lines - rows.transcript_height)
  local status_arg
  local status_text = ""
  local cwd
  local frame = {}
  local frame_width

  state.scroll_offset = clamp(state.scroll_offset, 0, max_scroll)

  if state.force_physical_clear then
    psi.tui_clear(true)
  end
  state.force_physical_clear = false
  frame_width = math.max(1, state.width - 1)
  cwd = psi.cwd() or "."
  frame[#frame + 1] =
    frame_line(rows.header_row, tui.compose_bar(tui.workspace_bar(cwd), frame_width), frame_width)

  local first_line = total_lines - rows.transcript_height - state.scroll_offset + 1
  if first_line < 1 then
    first_line = 1
  end
  local transcript_lines = build_render_window(state, first_line, rows.transcript_height)
  for i = 0, rows.transcript_height - 1 do
    local line = transcript_lines[i + 1]
    local row = rows.transcript_start + i
    frame[#frame + 1] = frame_line(row, line and style_line(line) or "", frame_width)
  end

  status_arg = {
    model = state.model and state.model.id or state.opts.model,
    provider = state.model and state.model.provider or nil,
    context_window = state.model and state.model.context_window or nil,
    busy = state.busy,
    busy_label = state.busy_label,
    elapsed_seconds = state.busy_started_at and (os.time() - state.busy_started_at) or 0,
    busy_phase = state.busy_phase,
    scroll = state.scroll_offset,
    editor_mode = state.editor_mode,
    selection_kind = state.selection_kind,
  }

  if state.status_text ~= nil then
    status_text = state.status_is_error and ansi.bold(ansi.red(state.status_text))
      or ansi.dim(state.status_text)
  elseif state.busy then
    status_text = tui.render_busy_status(
      state.busy_label or "gooning",
      state.busy_phase,
      status_arg.elapsed_seconds,
      state.busy_tick
    )
  end
  if rows.status_visible then
    frame[#frame + 1] = frame_line(rows.status_row, status_text, frame_width)
  end

  local input_width = frame_width
  frame[#frame + 1] =
    frame_line(rows.input_start_row, style_input_fill(input_width, "rail"), frame_width)
  for i = 0, rows.input_rows - 1 do
    local line_index = rows.input_first_line + i
    local line = rows.input_lines[line_index]
    local prefix = line_index == 1 and state.input_layout.prefix_first
      or state.input_layout.prefix_rest
    local text = ""
    if line ~= nil then
      text = render_input_text(state, line)
    end
    local input_text
    if input_line_selected and input_line_selected(state, line) then
      input_text = ansi.color("7", input_box_line(prefix .. text, input_width))
    else
      input_text = input_box_line(
        style_input_prefix(prefix, line_index == 1)
          .. (
            line and render_input_text_with_cursor(state, line, line_index == rows.cursor_line)
            or style_input_text(text)
          ),
        input_width
      )
    end
    frame[#frame + 1] = frame_line(rows.input_start_row + 1 + i, input_text, frame_width)
  end
  frame[#frame + 1] = frame_line(
    rows.input_start_row + rows.input_rows + 1,
    style_input_fill(input_width, "rail"),
    frame_width
  )

  frame[#frame + 1] = frame_line(
    rows.footer_row,
    tui.compose_bar(tui.status_bar(status_arg) or "", frame_width),
    frame_width
  )
  local visible_cursor_line = rows.cursor_line - rows.input_first_line + 1
  local cursor_prefix = rows.cursor_line == 1 and state.input_layout.prefix_first
    or state.input_layout.prefix_rest
  local cursor_row = rows.input_start_row + visible_cursor_line
  local cursor_col = display_width(cursor_prefix) + rows.cursor_col + 1
  cursor_row = clamp(cursor_row, rows.input_start_row + 1, rows.input_start_row + rows.input_rows)
  cursor_col = clamp(cursor_col, 1, math.max(1, state.width - 1))
  if type(psi.tui_render_frame) == "function" then
    psi.tui_render_frame(table.concat(frame), cursor_row, cursor_col, false)
  else
    psi.tui_set_cursor(1, 1, false)
    for _, line in ipairs(frame) do
      psi.tui_draw_raw_line(1, line)
    end
    psi.tui_set_cursor(cursor_row, cursor_col, false)
    psi.tui_refresh()
  end
  state.dirty = false
end

local function byte_at(text, pos)
  if pos < 0 or pos >= #text then
    return nil
  end
  return text:byte(pos + 1)
end

local function line_bounds(text, pos)
  text = text or ""
  pos = clamp(tonumber(pos) or 0, 0, #text)
  local start = pos
  while start > 0 and text:byte(start) ~= 10 do
    start = start - 1
  end
  local finish = pos
  while finish < #text and text:byte(finish + 1) ~= 10 do
    finish = finish + 1
  end
  return start, finish
end

local function line_col_at(text, pos)
  local start = line_bounds(text, pos)
  local line = 1
  local scan = 1
  while scan <= start do
    if text:byte(scan) == 10 then
      line = line + 1
    end
    scan = scan + 1
  end
  return line, pos - start
end

local function line_start_for(text, target_line)
  local line = 1
  local pos = 0
  while line < target_line and pos < #text do
    pos = pos + 1
    if text:byte(pos) == 10 then
      line = line + 1
    end
  end
  return pos
end

local function line_count(text)
  local count = 1
  for i = 1, #(text or "") do
    if text:byte(i) == 10 then
      count = count + 1
    end
  end
  return count
end

local function move_line(state, delta)
  local line, col = line_col_at(state.input, state.cursor)
  local target_line = clamp(line + delta, 1, line_count(state.input))
  local line_start = line_start_for(state.input, target_line)
  local _, line_finish = line_bounds(state.input, line_start)
  state.cursor = math.min(line_start + col, line_finish)
  state.dirty = true
end

local function move_line_start(state, first_nonblank)
  local start, finish = line_bounds(state.input, state.cursor)
  if first_nonblank then
    while start < finish do
      local b = byte_at(state.input, start)
      if b == nil or not (b == 32 or b == 9) then
        break
      end
      start = start + 1
    end
  end
  state.cursor = start
  state.dirty = true
end

local function move_line_end(state)
  local _, finish = line_bounds(state.input, state.cursor)
  state.cursor = finish
  state.dirty = true
end

local function set_insert_mode(state)
  clear_selection(state)
  state.block_edit = nil
  state.editor_mode = "insert"
  state.pending_key = nil
  state.dirty = true
end

local function open_line(state, above)
  local start, finish = line_bounds(state.input, state.cursor)
  if above then
    state.input = state.input:sub(1, start) .. "\n" .. state.input:sub(start + 1)
    state.cursor = start
  else
    state.input = state.input:sub(1, finish) .. "\n" .. state.input:sub(finish + 1)
    state.cursor = finish + 1
  end
  set_insert_mode(state)
end

local function clear_buffer(state)
  state.input = ""
  state.cursor = 0
  clear_selection(state)
  state.block_edit = nil
  state.editor_mode = "insert"
  state.pending_key = nil
  state.force_physical_clear = true
  state.dirty = true
end

function clear_selection(state)
  state.selection_anchor = nil
  state.selection_kind = nil
end

local function apply_block_edit(state)
  local edit = state.block_edit
  if edit == nil then
    return
  end
  state.block_edit = nil
  local inserted = ""
  if state.cursor >= edit.start_cursor then
    inserted = state.input:sub(edit.start_cursor + 1, state.cursor)
  end
  if inserted == "" then
    return
  end
  for i = #edit.targets, 1, -1 do
    local target = edit.targets[i]
    if target.line ~= edit.primary_line then
      local line_start = line_start_for(state.input, target.line)
      local _, line_finish = line_bounds(state.input, line_start)
      local pos = math.min(line_start + target.col, line_finish)
      state.input = state.input:sub(1, pos) .. inserted .. state.input:sub(pos + 1)
      if pos <= state.cursor then
        state.cursor = state.cursor + #inserted
      end
    end
  end
end

local function set_editor_mode(state, mode, kind)
  if mode ~= "insert" then
    apply_block_edit(state)
  end
  state.editor_mode = mode or "insert"
  if state.editor_mode == "visual" then
    state.selection_kind = kind or "char"
    if state.selection_kind == "line" then
      state.selection_anchor = line_bounds(state.input, state.cursor)
    else
      state.selection_anchor = state.cursor
    end
  else
    clear_selection(state)
  end
  state.pending_key = nil
  state.dirty = true
end

local function block_edit_targets(state, append)
  local text = state.input or ""
  local anchor = tonumber(state.selection_anchor) or state.cursor
  local start_line, start_col = line_col_at(text, anchor)
  local end_line, end_col = line_col_at(text, state.cursor)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  if start_col > end_col then
    start_col, end_col = end_col, start_col
  end
  local col = append and (end_col + 1) or start_col
  local targets = {}
  for line = start_line, end_line do
    targets[#targets + 1] = { line = line, col = col }
  end
  return targets
end

local function start_block_edit(state, append)
  if state.editor_mode ~= "visual" or state.selection_kind ~= "block" then
    return
  end
  local targets = block_edit_targets(state, append)
  if #targets == 0 then
    return
  end
  local primary = targets[1]
  local line_start = line_start_for(state.input, primary.line)
  local _, line_finish = line_bounds(state.input, line_start)
  local pos = math.min(line_start + primary.col, line_finish)
  state.cursor = pos
  state.block_edit = {
    targets = targets,
    primary_line = primary.line,
    start_cursor = pos,
  }
  clear_selection(state)
  state.editor_mode = "insert"
  state.pending_key = nil
  state.dirty = true
end

local function char_selection_range(state)
  local anchor = tonumber(state.selection_anchor) or state.cursor
  local start = math.min(anchor, state.cursor)
  local finish = math.max(anchor, state.cursor)
  if start == finish and start < #state.input then
    finish = finish + 1
  end
  return start, finish
end

local function line_selection_range(state)
  local anchor = tonumber(state.selection_anchor) or state.cursor
  local start = math.min(anchor, state.cursor)
  local finish = math.max(anchor, state.cursor)
  start = line_bounds(state.input, start)
  local _, line_finish = line_bounds(state.input, finish)
  if line_finish < #state.input and state.input:byte(line_finish + 1) == 10 then
    line_finish = line_finish + 1
  end
  return start, line_finish
end

local function block_selection_ranges(state)
  local text = state.input or ""
  local anchor = tonumber(state.selection_anchor) or state.cursor
  local start_line, start_col = line_col_at(text, anchor)
  local end_line, end_col = line_col_at(text, state.cursor)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  if start_col > end_col then
    start_col, end_col = end_col, start_col
  end
  local ranges = {}
  for line = start_line, end_line do
    local line_start = line_start_for(text, line)
    local _, line_finish = line_bounds(text, line_start)
    local first = math.min(line_start + start_col, line_finish)
    local last = math.min(line_start + end_col + 1, line_finish)
    if first < last then
      ranges[#ranges + 1] = { start = first, finish = last }
    end
  end
  return ranges
end

local function selection_ranges(state)
  if state.editor_mode ~= "visual" or state.selection_anchor == nil then
    return {}
  end
  if state.selection_kind == "block" then
    return block_selection_ranges(state)
  end
  local start, finish
  if state.selection_kind == "line" then
    start, finish = line_selection_range(state)
  else
    start, finish = char_selection_range(state)
  end
  if finish <= start then
    return {}
  end
  return { { start = start, finish = finish } }
end

function input_line_selected(state, line)
  if
    state.editor_mode ~= "visual"
    or state.selection_kind ~= "line"
    or state.selection_anchor == nil
    or line == nil
  then
    return false
  end
  local anchor = tonumber(state.selection_anchor) or state.cursor
  local start_pos = math.min(anchor, state.cursor)
  local finish_pos = math.max(anchor, state.cursor)
  local selected_start = line_bounds(state.input, start_pos)
  local _, selected_finish = line_bounds(state.input, finish_pos)
  local line_start = line.start
  local line_finish = line.start + line.len
  if line.len == 0 then
    return line_start >= selected_start and line_start <= selected_finish
  end
  return line_finish >= selected_start and line_start <= selected_finish
end

local function selected_text(state)
  local ranges = selection_ranges(state)
  local pieces = {}
  for _, range in ipairs(ranges) do
    pieces[#pieces + 1] = state.input:sub(range.start + 1, range.finish)
  end
  return table.concat(pieces, state.selection_kind == "block" and "\n" or "")
end

local function yank_selection(state)
  local text = selected_text(state)
  if text == "" and state.input ~= "" then
    text = state.input
  end
  state.clipboard = text
  if text ~= "" and tui.write_clipboard then
    tui.write_clipboard(text, {
      source = "tui-yank",
      state = state,
      disabled = state.clipboard_writers_disabled,
    })
  end
  set_status(state, text ~= "" and "yanked" or "nothing to yank", text == "")
  state.block_edit = nil
  set_editor_mode(state, "normal")
end

local function yank_input(state)
  state.clipboard = state.input or ""
  if state.clipboard ~= "" and tui.write_clipboard then
    tui.write_clipboard(state.clipboard, {
      source = "tui-yank",
      state = state,
      disabled = state.clipboard_writers_disabled,
    })
  end
  set_status(
    state,
    state.clipboard ~= "" and "yanked prompt" or "nothing to yank",
    state.clipboard == ""
  )
  state.dirty = true
end

function render_input_text(state, line)
  local text = sanitize_terminal_text(state.input:sub(line.start + 1, line.start + line.len), false)
  if state.selection_kind == "line" then
    return text
  end
  if state.editor_mode ~= "visual" then
    return text
  end
  local line_start = line.start
  local line_finish = line.start + line.len
  local ranges = selection_ranges(state)
  if #ranges == 0 then
    return text
  end
  local out = {}
  local cursor = line_start
  for _, range in ipairs(ranges) do
    local start = math.max(range.start, line_start)
    local finish = math.min(range.finish, line_finish)
    if start < finish then
      if cursor < start then
        out[#out + 1] = sanitize_terminal_text(state.input:sub(cursor + 1, start), false)
      end
      out[#out + 1] =
        ansi.color("7", sanitize_terminal_text(state.input:sub(start + 1, finish), false))
      cursor = finish
    end
  end
  if cursor < line_finish then
    out[#out + 1] = sanitize_terminal_text(state.input:sub(cursor + 1, line_finish), false)
  end
  return table.concat(out)
end

function render_input_text_with_cursor(state, line, draw_cursor)
  if not draw_cursor or state.editor_mode == "visual" then
    return style_input_text(render_input_text(state, line))
  end
  local text = state.input:sub(line.start + 1, line.start + line.len)
  local offset = clamp(state.cursor - line.start, 0, line.len)
  local before = sanitize_terminal_text(text:sub(1, offset), false)
  local cell
  local after
  if offset < #text then
    cell = sanitize_terminal_text(text:sub(offset + 1, offset + 1), false)
    after = sanitize_terminal_text(text:sub(offset + 2), false)
  else
    cell = " "
    after = ""
  end
  return style_input_text(before) .. style_input_cursor(cell) .. style_input_text(after)
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

local function move_word_start_forward(state)
  local pos = state.cursor
  while pos < #state.input do
    local b = byte_at(state.input, pos)
    if b == nil or is_space_byte(b) then
      break
    end
    pos = pos + 1
  end
  while pos < #state.input do
    local b = byte_at(state.input, pos)
    if b == nil or not is_space_byte(b) then
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

local function compact_status_text(text, max_len)
  text = tostring(text or "")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  max_len = tonumber(max_len) or 80
  if #text > max_len then
    return text:sub(1, math.max(1, max_len - 3)) .. "..."
  end
  return text
end

local function queued_messages_text()
  local pieces = {}
  for _, item in ipairs(agent.pending_messages() or {}) do
    local text = compact_status_text(item and item.text or "", 96)
    if text ~= "" then
      pieces[#pieces + 1] = text
    end
  end
  return table.concat(pieces, " | ")
end

local function queue_status_text(extra_text)
  local preview = queued_messages_text()
  extra_text = compact_status_text(extra_text or "", 96)
  if extra_text ~= "" then
    preview = preview ~= "" and (preview .. " | " .. extra_text) or extra_text
  end
  if preview == "" then
    return "queue empty"
  end
  return "queued: " .. preview
end

local function busy_command_action(line)
  if line == "/queue" or line == "/queue list" then
    return {
      kind = "print",
      payload = queued_messages_text() ~= "" and ("queued: " .. queued_messages_text())
        or "queue is empty",
    }
  end
  if line:match("^/btw%s+") then
    return { kind = "btw" }
  end
  return nil
end

local function queue_current_input(state, line)
  local count = agent.pending_message_count()
  if
    state.queue_nav_index ~= nil
    and state.queue_nav_index >= 1
    and state.queue_nav_index <= count
  then
    if agent.replace_pending(state.queue_nav_index, line) then
      state.queue_nav_index = nil
      set_status(state, queue_status_text(), false)
      state.dirty = true
      return
    end
  end
  if agent.queue_follow_up(line) then
    state.queue_nav_index = nil
    set_status(state, queue_status_text(), false)
  else
    set_status(state, "failed to queue message", true)
  end
  state.dirty = true
end

local function navigate_queue(state, direction)
  local count = agent.pending_message_count()
  if count == 0 then
    state.queue_nav_index = nil
    set_status(state, "queue is empty", false)
    return
  end
  local index = state.queue_nav_index
  if index == nil or index < 1 or index > count then
    index = direction == "previous" and count or 1
  elseif direction == "previous" then
    index = index - 1
    if index < 1 then
      index = count
    end
  else
    index = index + 1
    if index > count then
      index = 1
    end
  end

  local item = agent.pending_message(index)
  if item == nil then
    return
  end
  state.queue_nav_index = index
  state.input = item.text or ""
  state.cursor = #state.input
  set_status(state, queue_status_text(), false)
  state.dirty = true
end

local function restore_queued_message(state)
  local count = agent.pending_message_count()
  if count == 0 then
    state.queue_nav_index = nil
    set_status(state, "queue is empty", false)
    return
  end
  local messages = {}
  for _, item in ipairs(agent.pending_messages() or {}) do
    messages[#messages + 1] = item.text or ""
  end
  if #messages == 0 then
    state.queue_nav_index = nil
    set_status(state, "queue is empty", false)
    return
  end
  for i = count, 1, -1 do
    agent.remove_pending(i)
  end
  local current = tostring(state.input or "")
  local queued_text = table.concat(messages, "\n\n")
  local combined = queued_text
  if current:gsub("%s+", "") ~= "" then
    combined = queued_text .. "\n\n" .. current
  end
  state.queue_nav_index = nil
  state.input = combined
  state.cursor = #state.input
  clear_selection(state)
  state.block_edit = nil
  state.editor_mode = "insert"
  set_status(state, "editing queued messages", false)
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
  if not state.show_thinking then
    return
  end
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
  local payload = nil
  if chunk:sub(1, 1) == "{" and chunk:find('"psi_progress_replace"', 1, true) then
    payload = safe_decode(chunk, nil)
  end
  local index = find_entry_by_tool_id(state, "tool_result", tool_call_id)
  if index == nil then
    index = add_entry(state, "tool_result", "", nil, false, tool_call_id)
  end
  if type(payload) == "table" and payload.psi_progress_replace == true then
    local entry = state.entries[index]
    if entry then
      set_entry_text(state, index, limit_live_tool_progress_text(tostring(payload.text or "")))
    end
  else
    local entry = state.entries[index]
    set_entry_text(state, index, limit_live_tool_progress_text((entry and entry.text or "") .. chunk))
  end
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
    entry.is_error = not not is_error
    set_entry_text(state, index, text or "")
  else
    add_entry(state, "tool_result", text or "", tool_name, is_error, tool_call_id)
  end

  scroll_anchor_after(state, before)
end

local function observer_queued_user(state, text, kind)
  local before = scroll_anchor_before(state)
  finish_streaming_assistant(state)
  state.streaming_thinking_index = nil
  state.streaming_assistant_index = nil
  if state.queue_nav_index ~= nil and state.input == (text or "") then
    state.input = ""
    state.cursor = 0
    clear_selection(state)
    state.block_edit = nil
    state.editor_mode = "insert"
  end
  state.queue_nav_index = nil
  add_entry(state, "user", text or "")
  set_status(state, kind == "steering" and "using queued steering" or "using queued message", false)
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
    on_queued_user = function(text, kind)
      observer_queued_user(state, text, kind)
    end,
  }

  fire_turn_event(state, "before-turn", { text = line or "" })
  local ran, ok, reply = xpcall(function()
    return agent.run_turn({
      user_text = line or "",
      model = state.opts.model,
      max_tokens = state.opts.max_tokens,
      thinking_level = state.opts.thinking_level,
      reasoning_effort = state.opts.reasoning_effort,
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
  state.busy_kind = "compact"
  state.busy_label = "compacting"
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = os.time()
  psi.abort_reset()
  set_status(state, "", false)
  redraw(state)

  local ran, ok, summary = xpcall(function()
    return agent.run_compact({
      keep_recent = keep_recent,
      model = state.opts.model,
      max_tokens = state.opts.max_tokens,
      thinking_level = state.opts.thinking_level,
      reasoning_effort = state.opts.reasoning_effort,
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
  state.busy_kind = nil
  state.busy_label = nil
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = nil
  state.dirty = true
  redraw(state)
end

local function reset_busy(state)
  state.busy = false
  state.busy_kind = nil
  state.busy_label = nil
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = nil
end

local function run_btw(state, question)
  question = tostring(question or "")
  if question == "" then
    add_entry(state, "btw", "/btw")
    append_entry_text(state, #state.entries, "\nusage: /btw <question>")
    return true
  end

  local entry_index = add_entry(state, "btw", "/btw " .. question .. "\n")
  state.scroll_offset = 0
  state.busy = true
  state.busy_kind = "btw"
  state.busy_label = "btw"
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = os.time()
  psi.abort_reset()
  set_status(state, "", false)
  redraw(state)

  local ran, ok, answer = xpcall(function()
    return sched.run(function()
      return agent.side_question(question, {
        model = state.opts.model,
        max_tokens = 1024,
        context_chars = 24000,
        abort_check = psi.is_aborted,
      })
    end)
  end, debug.traceback)

  if not ran then
    append_entry_text(state, entry_index, "btw failed: " .. tostring(ok or "side question failed"))
    set_status(state, "btw failed", true)
  elseif not ok then
    append_entry_text(
      state,
      entry_index,
      "btw failed: " .. tostring(answer or "side question failed")
    )
    set_status(state, "btw failed", true)
  else
    append_entry_text(state, entry_index, answer or "")
    set_status(state, "", false)
  end

  reset_busy(state)
  state.dirty = true
  redraw(state)
  return true
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

  if action.kind == "ansi-print" then
    rebuild_from_session(state)
    if type(action.payload) == "string" and action.payload ~= "" then
      add_entry(state, "ansi", action.payload)
    end
    set_status(state, "", false)
    return true
  end

  if action.kind == "btw" then
    run_btw(state, action.payload)
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

  if
    tui.handle_command_action
    and tui.handle_command_action(action, {
      set_status = function(text, is_error)
        set_status(state, text, is_error)
      end,
      reset_editor = function()
        state.editor_mode = "insert"
        clear_selection(state)
        state.block_edit = nil
        state.pending_key = nil
        state.dirty = true
      end,
    })
  then
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

  if action.kind == "set-reasoning-effort" then
    agent.set_reasoning_effort(action.payload)
    state.opts.reasoning_effort = action.payload
    state.opts.thinking_level = action.payload == "none" and "off" or action.payload
    add_entry(state, "info", "reasoning effort set to " .. tostring(action.payload or "none"))
    set_status(state, "", false)
    return true
  end

  if action.kind == "set-thinking" then
    local ok, level = agent.set_thinking_level(action.payload, state.opts.model)
    if not ok then
      set_status(state, tostring(level), true)
      return true
    end
    state.opts.thinking_level = level
    state.opts.reasoning_effort = level == "off" and "none" or level
    add_entry(state, "info", "thinking set to " .. tostring(level))
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
  if state.input == "" then
    return
  end

  local line = state.input
  state.input = ""
  state.cursor = 0
  clear_selection(state)
  state.block_edit = nil
  state.editor_mode = "insert"
  state.pending_key = nil

  if state.busy then
    if state.busy_kind ~= "agent" then
      state.input = line
      state.cursor = #state.input
      set_status(state, "busy", true)
      state.dirty = true
      return
    end
    if line:sub(1, 1) == "/" then
      local action = busy_command_action(line)
      if action == nil then
        state.input = line
        state.cursor = #state.input
        set_status(state, "command unavailable while busy", true)
        return
      end
      if action.kind == "print" then
        if type(action.payload) == "string" and action.payload ~= "" then
          add_entry(state, "info", action.payload)
        end
        set_status(state, "", false)
        return
      end
      if action.kind == "btw" then
        state.input = line
        state.cursor = #state.input
        set_status(state, "/btw is unavailable while a turn is running", true)
        return
      end
      if action.kind == "expand" then
        line = action.payload or ""
      else
        state.input = line
        state.cursor = #state.input
        set_status(state, "command unavailable while busy", true)
        return
      end
    end
    queue_current_input(state, line)
    return
  end

  if line:sub(1, 1) == "/" then
    local handled, expanded = handle_command(state, line)
    if handled then
      return
    end
    line = expanded or ""
  end

  add_entry(state, "user", line)
  state.streaming_assistant_index = add_entry(state, "assistant", "")
  state.show_thinking = tui.show_thinking() == "1"
  state.scroll_offset = 0
  state.busy = true
  state.busy_kind = "agent"
  state.busy_label = tui.pick_busy_status() or "gooning"
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = os.time()
  psi.abort_reset()
  set_status(state, "", false)
  redraw(state)
  local turn_ok = run_turn(state, line)
  state.busy = false
  state.busy_kind = nil
  state.busy_label = nil
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_started_at = nil
  if not turn_ok then
    state.force_physical_clear = true
  end
  state.dirty = true
end

local function apply_action(state, action, arg)
  if action == nil or action == "" or action == "noop" then
    state.pending_key = nil
    return
  end
  if action ~= "vim-pending" then
    state.pending_key = nil
  end
  if action == "insert" then
    if state.editor_mode == "visual" then
      clear_selection(state)
    end
    state.editor_mode = "insert"
    insert_text(state, arg or "")
    return
  end
  if action == "submit" then
    submit(state)
    return
  end
  if action == "queue-navigate" then
    navigate_queue(state, arg)
    return
  end
  if action == "queue-restore" then
    restore_queued_message(state)
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
  if action == "move-line-start" then
    move_line_start(state, false)
    return
  end
  if action == "move-line-first-nonblank" then
    move_line_start(state, true)
    return
  end
  if action == "move-line-end" then
    move_line_end(state)
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
  if action == "move-word-start-right" then
    move_word_start_forward(state)
    return
  end
  if action == "move-line-up" then
    move_line(state, -1)
    return
  end
  if action == "move-line-down" then
    move_line(state, 1)
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
  if action == "clear-buffer" then
    clear_buffer(state)
    return
  end
  if action == "scroll" then
    if arg == "page-up" then
      scroll_by(state, math.max(4, math.floor(state.height / 2)))
    elseif arg == "page-down" then
      scroll_by(state, -math.max(4, math.floor(state.height / 2)))
    elseif arg == "top" then
      state.scroll_offset = max_scroll_offset(state)
      state.dirty = true
    elseif arg == "bottom" then
      state.scroll_offset = 0
      state.dirty = true
    elseif arg == "line-up" then
      scroll_by(state, 1)
    elseif arg == "line-down" then
      scroll_by(state, -1)
    end
    return
  end
  if action == "redraw" then
    state.force_physical_clear = true
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
    return
  end
  if action == "vim-mode" then
    arg = type(arg) == "table" and arg or {}
    set_editor_mode(state, arg.mode, arg.kind)
    return
  end
  if action == "vim-append" then
    if state.cursor < #state.input then
      state.cursor = state.cursor + 1
    end
    set_insert_mode(state)
    return
  end
  if action == "vim-append-line" then
    move_line_end(state)
    set_insert_mode(state)
    return
  end
  if action == "vim-insert-line" then
    move_line_start(state, true)
    set_insert_mode(state)
    return
  end
  if action == "vim-block-insert" then
    start_block_edit(state, false)
    return
  end
  if action == "vim-block-append" then
    start_block_edit(state, true)
    return
  end
  if action == "vim-open-line-below" then
    open_line(state, false)
    return
  end
  if action == "vim-open-line-above" then
    open_line(state, true)
    return
  end
  if action == "vim-pending" then
    state.pending_key = arg
    state.dirty = true
    return
  end
  if action == "vim-yank" then
    if state.editor_mode == "visual" then
      yank_selection(state)
    else
      yank_input(state)
    end
    return
  end
  if action == "vim-paste" then
    if state.clipboard ~= nil and state.clipboard ~= "" then
      insert_text(state, state.clipboard)
    else
      set_status(state, "clipboard empty", true)
    end
    return
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
    input = state.input,
    cursor = state.cursor,
    editor_mode = state.editor_mode,
    selection_kind = state.selection_kind,
    selection_anchor = state.selection_anchor,
    pending_key = state.pending_key,
    scroll = state.scroll_offset,
    queue_count = agent.pending_message_count(),
    text = event.text or "",
  })
  if result == nil then
    state.pending_key = nil
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
    state.busy_tick = (state.busy_tick or 0) + 1
    state.dirty = true
    if state.busy_tick % 4 == 0 then
      state.busy_phase = ((state.busy_phase or 0) % 3) + 1
    end
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
  agent.configure(opts)
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
    cursor_screen_col = display_width(
      cursor_line == 1 and state.input_layout.prefix_first or state.input_layout.prefix_rest
    )
      + cursor_col
      + 1,
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

function M._debug_layout_rows(width, height, busy, status_text)
  local state = {
    width = tonumber(width) or 80,
    height = tonumber(height) or 24,
    busy = not not busy,
    status_text = status_text,
    input = "",
    cursor = 0,
    scroll_offset = 0,
    input_layout = default_input_layout(tonumber(height) or 24),
  }
  return layout_rows(state)
end

function M._debug_tui_capabilities()
  return detect_tui_capabilities()
end

function M._debug_sanitize_terminal_text(text, preserve_newlines)
  return sanitize_terminal_text(text, preserve_newlines)
end

function M._debug_limit_live_tool_progress_text(text)
  return limit_live_tool_progress_text(text)
end

function M._debug_edit_keys(input, cursor, events, apply_startup_hooks, debug_options)
  debug_options = type(debug_options) == "table" and debug_options or {}
  local state = {
    opts = {},
    model = {},
    entries = {},
    input = input or "",
    cursor = tonumber(cursor) or #(input or ""),
    editor_mode = "insert",
    selection_anchor = nil,
    selection_kind = nil,
    clipboard = "",
    clipboard_writers_disabled = debug_options.clipboard_writers ~= true,
    pending_key = nil,
    block_edit = nil,
    force_physical_clear = false,
    busy = not not debug_options.busy,
    busy_kind = debug_options.busy_kind or (debug_options.busy and "agent" or nil),
    running = true,
    scroll_offset = 0,
    status_text = nil,
    status_is_error = false,
    width = 80,
    height = 24,
    input_layout = default_input_layout(24),
    dirty = false,
  }
  if apply_startup_hooks and tui.run_startup_hooks then
    tui.run_startup_hooks({ opts = {}, state = state })
  end
  for _, event in ipairs(events or {}) do
    handle_key_event(state, event)
  end
  local lines = build_input_lines(state)
  local rendered = {}
  for i, line in ipairs(lines) do
    local prefix = i == 1 and state.input_layout.prefix_first or state.input_layout.prefix_rest
    rendered[i] = prefix .. render_input_text(state, line)
    if input_line_selected(state, line) then
      rendered[i] = ansi.color("7", rendered[i] .. " ")
    end
  end
  return {
    input = state.input,
    cursor = state.cursor,
    editor_mode = state.editor_mode,
    selection_anchor = state.selection_anchor,
    selection_kind = state.selection_kind,
    clipboard = state.clipboard,
    pending_key = state.pending_key,
    queue_nav_index = state.queue_nav_index,
    block_edit = state.block_edit,
    scroll_offset = state.scroll_offset,
    status_text = state.status_text,
    rendered = rendered,
  }
end

function M._debug_consume_queued_preview(input, queued_text)
  local state = {
    opts = {},
    model = {},
    entries = {},
    input = input or "",
    cursor = #(input or ""),
    editor_mode = "insert",
    selection_anchor = nil,
    selection_kind = nil,
    clipboard = "",
    pending_key = nil,
    queue_nav_index = 1,
    block_edit = nil,
    force_physical_clear = false,
    busy = true,
    running = true,
    scroll_offset = 0,
    status_text = nil,
    status_is_error = false,
    width = 80,
    height = 24,
    input_layout = default_input_layout(24),
    dirty = false,
  }
  observer_queued_user(state, queued_text or "", "follow-up")
  return {
    input = state.input,
    cursor = state.cursor,
    editor_mode = state.editor_mode,
    queue_nav_index = state.queue_nav_index,
    status_text = state.status_text,
  }
end

function M._debug_redraw_counts(input)
  local names = {
    "tui_size",
    "tui_clear",
    "tui_draw_line",
    "tui_draw_raw_line",
    "tui_render_frame",
    "tui_set_cursor",
    "tui_refresh",
    "cwd",
    "session_id",
    "session_message_count",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = psi[name]
  end
  local calls = {
    draw_rows = {},
    raw_rows = {},
    frames = {},
    clears = 0,
    cursor_sets = 0,
    refreshes = 0,
  }
  local function reset_calls()
    calls.draw_rows = {}
    calls.raw_rows = {}
    calls.frames = {}
    calls.clears = 0
    calls.cursor_sets = 0
    calls.refreshes = 0
  end
  psi.tui_size = function()
    return { width = 80, height = 24 }
  end
  psi.tui_clear = function(force)
    if force then
      calls.clears = calls.clears + 1
    end
  end
  psi.tui_draw_line = function(row, text)
    calls.draw_rows[#calls.draw_rows + 1] = { row = row, text = text or "" }
  end
  psi.tui_draw_raw_line = function(row, text)
    calls.raw_rows[#calls.raw_rows + 1] = { row = row, text = text or "" }
  end
  psi.tui_render_frame = function(frame, row, col, visible)
    calls.frames[#calls.frames + 1] = {
      frame = frame or "",
      row = row,
      col = col,
      visible = visible,
    }
  end
  psi.tui_set_cursor = function()
    calls.cursor_sets = calls.cursor_sets + 1
  end
  psi.tui_refresh = function()
    calls.refreshes = calls.refreshes + 1
  end
  psi.cwd = function()
    return "."
  end
  psi.session_id = function()
    return "debug-session"
  end
  psi.session_message_count = function()
    return 0
  end

  local ok, result = xpcall(function()
    local state = {
      opts = { model = "debug" },
      model = { id = "debug" },
      entries = {},
      input = input or "hello\nhi",
      cursor = #(input or "hello\nhi"),
      editor_mode = "insert",
      selection_anchor = nil,
      selection_kind = nil,
      clipboard = "",
      pending_key = nil,
      block_edit = nil,
      force_physical_clear = false,
      busy = true,
      busy_label = "gooning",
      busy_phase = 1,
      busy_tick = 0,
      busy_started_at = os.time(),
      running = true,
      scroll_offset = 0,
      status_text = nil,
      status_is_error = false,
      show_thinking = false,
      width = 80,
      height = 24,
      input_layout = default_input_layout(24),
      tui_caps = { raw_ansi = false },
      streaming_assistant_index = nil,
      streaming_thinking_index = nil,
      entries_version = 0,
      total_cache_width = nil,
      total_cache_version = nil,
      total_cache_lines = nil,
      dirty = true,
    }
    refresh_input_layout(state)
    local rows = layout_rows(state)
    redraw(state)
    local first_frames = #calls.frames
    reset_calls()
    state.busy_tick = 1
    state.dirty = true
    redraw(state)
    local second_frames = #calls.frames
    local second_frame = calls.frames[1] and calls.frames[1].frame or ""
    local second_input_draws = 0
    for row = rows.input_start_row, rows.input_start_row + rows.input_rows + 1 do
      if second_frame:find("\27%[" .. tostring(row) .. ";1H", 1, false) ~= nil then
        second_input_draws = second_input_draws + 1
      end
    end
    reset_calls()
    state.input = ""
    state.cursor = 0
    state.busy_tick = 2
    state.dirty = true
    redraw(state)
    local stale_clears = 0
    local stale_frame = calls.frames[1] and calls.frames[1].frame or ""
    local line_clears = stale_frame:find("\27%[2K", 1, false) ~= nil and 1 or 0
    for row = rows.transcript_start, rows.input_start_row - 1 do
      stale_clears = stale_clears
        + (stale_frame:find("\27%[" .. tostring(row) .. ";1H", 1, false) ~= nil and 1 or 0)
    end
    return {
      first_frames = first_frames,
      second_frames = second_frames,
      second_input_draws = second_input_draws,
      second_clears = calls.clears,
      stale_clears = stale_clears,
      line_clears = line_clears,
      raw_draws = #calls.raw_rows,
      draw_rows = #calls.draw_rows,
      cursor_sets = calls.cursor_sets,
      refreshes = calls.refreshes,
      second_frame = second_frame,
      stale_frame = stale_frame,
    }
  end, debug.traceback)

  for _, name in ipairs(names) do
    psi[name] = saved[name]
  end
  if not ok then
    error(result)
  end
  return result
end

return M
