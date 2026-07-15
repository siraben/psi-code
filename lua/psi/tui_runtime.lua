local agent = require("psi.agent_session")
local ansi = require("psi.ansi")
local commands = require("psi.slash_commands")
local context = require("psi.context")
local markdown = require("psi.markdown")
local prelude = require("psi.prelude")
local records = require("psi.records")
local render = require("psi.render")
local sched = require("psi.sched")
local session = require("psi.session_manager")
local settings = require("psi.settings_manager")
local tui = require("psi.tui_status")
local tui_markdown = require("psi.tui_components.markdown")
local tool_execution = require("psi.tui_components.tool_execution")
local tui_app = require("psi.tui_app")
local tui_component = require("psi.tui_component")
local tui_layout = require("psi.tui_layout")
local tui_renderer = require("psi.tui_renderer")
local tui_text = require("psi.tui_text")

local M = {}

local MAX_RENDER_TEXT = 8192
local MAX_RENDER_TRUNCATION_SUFFIX = "\n\n[output truncated]"
local MAX_COMMAND_COMPLETION_ROWS = 6
local PI_STYLE = {
  bg_tool_error = "48;5;52",
  bg_tool_pending = "48;5;236",
  bg_tool_success = "48;5;22",
  bg_selected = "48;5;237",
  bg_user_message = "48;5;238",
  border = "34",
  erase_to_eol = "\27[K",
  sgr_reset = "\27[0m",
}

local DEFAULT_WIDTH = 80
local DEFAULT_HEIGHT = 24
local MIN_SIZE = 1
local MIN_HEIGHT = 12
local PROMPT_RESERVED_ROWS = 6
local FRAME_WIDTH_MARGIN = 1

local TUI_CONST = {
  busy_animation_interval_ms = 600,
  byte_bel = 7,
  byte_backslash = 92,
  byte_cr = 13,
  byte_csi_final_end = 126,
  byte_csi_final_start = 64,
  byte_del = 127,
  byte_esc = 27,
  byte_ff = 12,
  byte_lf = 10,
  byte_space = 32,
  byte_tab = 9,
  byte_vtab = 11,
  char_apc = "_",
  char_csi = "[",
  char_dcs = "P",
  char_osc = "]",
  char_pm = "^",
  char_st = "\\",
  setting_prompt_max_rows = "tui.prompt.max_rows",
}

-- Bundled chat-layout helpers. Single local keeps tui_runtime under Lua's
-- 200-locals-per-function chunk limit.
local chat = { FRAME = "frame", CHAT = "chat" }

function chat.resolve_mode(opts)
  local explicit = opts and opts.layout_mode
  if explicit == chat.CHAT or explicit == chat.FRAME then
    return explicit
  end
  if settings.get("tui.layout.mode", chat.FRAME) == chat.CHAT then
    return chat.CHAT
  end
  return chat.FRAME
end

function chat.set_alt_screen(enter)
  if type(psi.tui_write) == "function" then
    if enter then
      psi.tui_write("\27[?1049h\27[?1000h\27[?1006h\27[?25h\27[2J\27[H")
    else
      psi.tui_write("\27[?1006l\27[?1000l\27[?2026l\27[0m\27[?25h\27[?1049l")
    end
  end
  if type(psi.tui_set_alt_screen_active) == "function" then
    psi.tui_set_alt_screen_active(enter)
  end
end

local EMPTY = ""
local NEWLINE = "\n"
local FALLBACK_PROMPT_PREFIX_FIRST = "> "
local FALLBACK_PROMPT_PREFIX_REST = "| "
local strip_ansi = tui_text.strip_ansi
local display_width = tui_text.visible_width

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
  return b == TUI_CONST.byte_space
    or b == TUI_CONST.byte_tab
    or b == TUI_CONST.byte_lf
    or b == TUI_CONST.byte_vtab
    or b == TUI_CONST.byte_ff
    or b == TUI_CONST.byte_cr
end

local function trim_trailing_newlines(text)
  text = text or EMPTY
  return (text:gsub(NEWLINE .. "+$", EMPTY))
end

local function now_ms()
  if type(psi) == "table" and type(psi.time_ms) == "function" then
    return tonumber(psi.time_ms()) or (os.time() * 1000)
  end
  return os.time() * 1000
end

local function trim_edge_newlines(text)
  text = trim_trailing_newlines(text)
  return (text:gsub("^" .. NEWLINE .. "+", EMPTY))
end

local function find_string_terminator(text, start)
  local i = start
  while i <= #text do
    local byte = text:byte(i)
    if byte == TUI_CONST.byte_bel then
      return i + 1
    end
    if byte == TUI_CONST.byte_esc and text:byte(i + 1) == TUI_CONST.byte_backslash then
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
    if byte >= TUI_CONST.byte_csi_final_start and byte <= TUI_CONST.byte_csi_final_end then
      return i + 1
    end
    i = i + 1
  end
  return #text + 1
end

local function sanitize_terminal_text(text, preserve_newlines, preserve_line_erase, preserve_sgr)
  text = tostring(text or EMPTY)
  if preserve_newlines then
    if text:find("[\0-\9\11-\31\127]") == nil then
      return text
    end
  elseif text:find("[\0-\31\127]") == nil then
    return text
  end

  local out = {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local next_char = text:sub(i + 1, i + 1)
    if byte == TUI_CONST.byte_esc then
      if next_char == TUI_CONST.char_csi then
        local csi_end = find_csi_terminator(text, i + 2)
        -- Preserve SGR (m-terminated) codes verbatim so foreground,
        -- background, bold, dim, etc. survive into the rendered TUI
        -- buffer. Drop every other CSI (cursor moves, scroll, etc.)
        -- because they would corrupt our line-based layout.
        local terminator = text:sub(csi_end - 1, csi_end - 1)
        if (preserve_sgr and terminator == "m") or (preserve_line_erase and terminator == "K") then
          out[#out + 1] = text:sub(i, csi_end - 1)
        end
        i = csi_end
      elseif
        next_char == TUI_CONST.char_osc
        or next_char == TUI_CONST.char_dcs
        or next_char == TUI_CONST.char_pm
        or next_char == TUI_CONST.char_apc
      then
        i = find_string_terminator(text, i + 2)
      elseif next_char == TUI_CONST.char_st then
        i = i + 2
      else
        i = i + 2
      end
    elseif byte == TUI_CONST.byte_lf and preserve_newlines then
      out[#out + 1] = NEWLINE
      i = i + 1
    elseif byte < TUI_CONST.byte_space or byte == TUI_CONST.byte_del then
      out[#out + 1] = " "
      i = i + 1
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function limit_text(text)
  text = text or EMPTY
  if #text <= MAX_RENDER_TEXT then
    return text
  end
  return text:sub(1, MAX_RENDER_TEXT) .. MAX_RENDER_TRUNCATION_SUFFIX
end

M._live_progress = {}

function M._live_progress.clip_line(line)
  line = tostring(line or EMPTY)
  if #line <= 1000 then
    return line
  end
  -- Keep just the tail; no "[earlier output truncated]" marker.
  return line:sub(#line - 1000 + 1)
end

function M._live_progress.push_line(entry, line)
  entry.progress_lines = entry.progress_lines or {}
  entry.progress_total_lines = (entry.progress_total_lines or 0) + 1
  entry.progress_lines[#entry.progress_lines + 1] = M._live_progress.clip_line(line)
  while #entry.progress_lines > 8 do
    table.remove(entry.progress_lines, 1)
  end
end

function M._live_progress.display(entry)
  local lines = {}
  for _, line in ipairs(entry.progress_lines or {}) do
    lines[#lines + 1] = line
  end
  local partial = entry.progress_partial or EMPTY
  local total = entry.progress_total_lines or 0
  if partial ~= EMPTY then
    lines[#lines + 1] = M._live_progress.clip_line(partial)
    total = total + 1
  end
  while #lines > 8 do
    table.remove(lines, 1)
  end
  local omitted = math.max(0, total - #lines)
  local body = table.concat(lines, NEWLINE)
  if omitted > 0 then
    local shown = #lines
    local header = "[Showing last " .. tostring(shown) .. " of " .. tostring(total) .. " lines]"
    return body ~= EMPTY and (header .. NEWLINE .. NEWLINE .. body) or header
  end
  return body
end

function M._live_progress.update(entry, chunk, replace)
  if replace then
    entry.progress_lines = {}
    entry.progress_partial = EMPTY
    entry.progress_total_lines = 0
  end
  chunk = tostring(chunk or EMPTY)
  if chunk == EMPTY then
    return M._live_progress.display(entry)
  end
  entry.progress_lines = entry.progress_lines or {}
  entry.progress_partial = entry.progress_partial or EMPTY
  entry.progress_total_lines = entry.progress_total_lines or 0

  chunk = chunk:gsub("\r\n", NEWLINE)
  local partial = entry.progress_partial
  local pos = 1
  while pos <= #chunk do
    local start_pos, end_pos, ch = chunk:find("([\r\n])", pos)
    if not start_pos then
      partial = partial .. chunk:sub(pos)
      break
    end
    if start_pos > pos then
      partial = partial .. chunk:sub(pos, start_pos - 1)
    end
    if ch == "\r" then
      partial = EMPTY
    else
      M._live_progress.push_line(entry, partial)
      partial = EMPTY
    end
    pos = end_pos + 1
  end
  entry.progress_partial = partial
  return M._live_progress.display(entry)
end

local function limit_live_tool_progress_text(text)
  local entry = {}
  return M._live_progress.update(entry, text or EMPTY, true)
end

local function fit_text(text, width)
  text = tostring(text or "")
  width = math.max(0, tonumber(width) or 0)
  if display_width(text) <= width then
    return text
  end
  local target = width <= 3 and width or (width - 3)
  if target <= 0 then
    return ""
  end
  local byte_index = tui_text.byte_index_for_width(text, target)
  return width <= 3 and text:sub(1, byte_index) or (text:sub(1, byte_index) .. "...")
end

local function pending_queue_lines(width, max_rows)
  width = math.max(1, tonumber(width) or DEFAULT_WIDTH)
  max_rows = max_rows ~= nil and math.max(0, tonumber(max_rows) or 0) or nil
  if type(agent.pending_messages) ~= "function" then
    return {}
  end

  local message_lines = {}
  for _, item in ipairs(agent.pending_messages() or {}) do
    local text = tostring(item and item.text or "")
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
      local label = item and item.kind == "steering" and "Steering" or "Follow-up"
      message_lines[#message_lines + 1] = ansi.dim(fit_text(label .. ": " .. text, width))
    end
  end
  if #message_lines == 0 then
    return {}
  end

  local key_text = "Alt-Up"
  local ok, keybindings = pcall(require, "psi.keybindings")
  if ok and keybindings and type(keybindings.display) == "function" then
    key_text = keybindings.display("tui.queue.restore")
  end
  local hint = ansi.dim(fit_text("↳ " .. key_text .. " to edit all queued messages", width))

  if max_rows == nil or max_rows >= (#message_lines + 2) then
    local out = { "" }
    for _, line in ipairs(message_lines) do
      out[#out + 1] = line
    end
    out[#out + 1] = hint
    return out
  end

  if max_rows <= 0 then
    return {}
  end
  if max_rows == 1 then
    return { hint }
  end

  local out = { "" }
  local visible_messages = math.max(0, max_rows - 2)
  local hidden = #message_lines - visible_messages
  if hidden > 0 and visible_messages > 0 then
    visible_messages = visible_messages - 1
  end
  for i = 1, visible_messages do
    out[#out + 1] = message_lines[i]
  end
  if hidden > 0 then
    out[#out + 1] = ansi.dim(fit_text("... " .. tostring(hidden) .. " more queued messages", width))
  end
  out[#out + 1] = hint
  return out
end

local function apply_bg_line(bg_code, text)
  text = tostring(text or "")
  if not ansi.enabled or not ansi.color_enabled then
    return text
  end
  local bg = "\27[" .. ansi.resolve(bg_code) .. "m"
  text = text:gsub("\27%[0m", PI_STYLE.sgr_reset .. bg)
  return bg .. text .. PI_STYLE.erase_to_eol .. PI_STYLE.sgr_reset
end

local function render_boxed_lines(source_lines, width, bg_code, padding_x, padding_y)
  width = math.max(1, tonumber(width) or 1)
  padding_x = math.max(0, tonumber(padding_x) or 0)
  padding_y = math.max(0, tonumber(padding_y) or 0)
  source_lines = type(source_lines) == "table" and source_lines or {}
  local content_width = math.max(1, width - (padding_x * 2))
  local pad = string.rep("", 0)
  if padding_x > 0 then
    pad = string.rep(" ", padding_x)
  end
  local out = {}
  for _ = 1, padding_y do
    out[#out + 1] = apply_bg_line(bg_code, string.rep(" ", width))
  end
  for _, line in ipairs(source_lines) do
    local clipped = line
    if display_width(clipped) > content_width then
      local limit = tui_text.byte_index_for_width(clipped, content_width)
      clipped = clipped:sub(1, limit)
    end
    local text = pad .. clipped
    text = text .. string.rep(" ", math.max(0, width - display_width(text)))
    out[#out + 1] = apply_bg_line(bg_code, text)
  end
  for _ = 1, padding_y do
    out[#out + 1] = apply_bg_line(bg_code, string.rep(" ", width))
  end
  return out
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

local function env_integer(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return nil
  end
  return tonumber(value)
end

local function inline_viewport_height(terminal_height)
  terminal_height = math.max(MIN_HEIGHT, tonumber(terminal_height) or DEFAULT_HEIGHT)
  if env_bool("PSI_TUI_ALT_SCREEN") == true or env_bool("PSI_TUI_FULLSCREEN") == true then
    return terminal_height
  end
  local max_rows = env_integer("PSI_TUI_INLINE_MAX_ROWS") or terminal_height
  return clamp(max_rows, MIN_HEIGHT, terminal_height)
end

local function detect_tui_capabilities()
  local platform = require("psi.platform")
  local info = type(psi.runtime_info) == "function" and psi.runtime_info() or {}
  local term = os.getenv("TERM") or ""
  local windows_ansi_ok = platform.is_windows() and platform.windows_ansi_supported()
  local ansi_ok = info.ansi ~= false and ((term ~= "" and term ~= "dumb") or windows_ansi_ok)
  local color_ok = ansi_ok and info.color ~= false
  local force_ansi = env_bool("PSI_ANSI")
  local force_color = env_bool("PSI_COLOR")

  if platform.is_windows() and not platform.windows_ansi_supported() then
    ansi_ok = false
    color_ok = false
  end
  if force_ansi ~= nil then
    ansi_ok = force_ansi and info.ansi ~= false
    color_ok = ansi_ok and info.color ~= false
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
    max_rows = settings.get(TUI_CONST.setting_prompt_max_rows, nil),
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

local function skip_wrapped_input_spaces(input, chunk_start, line_end)
  local next_start = chunk_start
  while next_start < line_end and input:byte(next_start + 1) == TUI_CONST.byte_space do
    next_start = next_start + 1
  end
  if next_start < line_end then
    return next_start
  end
  return chunk_start
end

local function input_wrap_break(input, chunk_start, limit, line_end)
  local break_at = nil
  local i = chunk_start
  while i < line_end and i < limit do
    if input:byte(i + 1) == TUI_CONST.byte_space then
      local j = i
      while j < line_end and input:byte(j + 1) == TUI_CONST.byte_space do
        j = j + 1
      end
      if j <= limit and j < line_end then
        break_at = j
      end
      i = j
    else
      i = i + 1
    end
  end
  return break_at
end

local function input_next_chunk_end(input, chunk_start, line_end, width)
  local remaining = input:sub(chunk_start + 1, line_end)
  if display_width(remaining) <= width then
    return line_end
  end
  local limit = tui_text.byte_index_for_width(remaining, width)
  if limit <= 0 then
    limit = 1
  end
  limit = math.min(line_end, chunk_start + limit)
  return input_wrap_break(input, chunk_start, limit, line_end) or limit
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
    while line_end < input_length and input:byte(line_end + 1) ~= TUI_CONST.byte_lf do
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
        local hidden_start = chunk_start
        if chunk_start > pos then
          chunk_start = skip_wrapped_input_spaces(input, chunk_start, line_end)
          if
            chunk_start > hidden_start
            and not cursor_found
            and state.cursor > hidden_start
            and state.cursor <= chunk_start
            and #lines > 0
          then
            local previous = lines[#lines]
            cursor_line = #lines
            cursor_col = display_width(input:sub(previous.start + 1, previous.start + previous.len))
            cursor_found = true
          end
        end
        local prefix = (#lines == 0) and state.input_layout.prefix_first
          or state.input_layout.prefix_rest
        local chunk_end =
          input_next_chunk_end(input, chunk_start, line_end, input_wrap_width(state.width, prefix))
        lines[#lines + 1] = { start = chunk_start, len = chunk_end - chunk_start }
        if not cursor_found and state.cursor >= chunk_start and state.cursor <= chunk_end then
          cursor_line = #lines
          cursor_col = display_width(input:sub(chunk_start + 1, state.cursor))
          cursor_found = true
        end
        chunk_start = chunk_end
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

local function active_command_completions(state)
  if state.busy or state.cursor ~= #(state.input or "") then
    state.command_completion_index = 1
    state.command_completion_input = nil
    state.command_completion_items = nil
    state.command_completion_start = nil
    return {}
  end
  local force = state.command_completion_force == true
    and state.command_completion_force_input == state.input
  if
    state.command_completion_input == state.input
    and state.command_completion_force_cached == force
    and state.command_completion_items
  then
    return state.command_completion_items
  end
  if state.command_completion_input ~= state.input then
    state.command_completion_index = 1
  end

  local result = commands.input_completions(state.input, state.cursor, 32, force)
  local items = (result and result.items) or {}
  state.command_completion_input = state.input
  state.command_completion_force_cached = force
  state.command_completion_items = items
  state.command_completion_start = result and result.start or nil
  if #items == 0 then
    state.command_completion_index = 1
    return items
  end
  state.command_completion_index = clamp(state.command_completion_index or 1, 1, #items)
  return items
end

local function accept_command_completion(state)
  local items = active_command_completions(state)
  local item = items[state.command_completion_index or 1]
  if not item then
    return false
  end
  local start = state.command_completion_start or 1
  local before = state.input:sub(1, start - 1)
  state.input = before .. tostring(item.insert or "") .. (item.trailing or "")
  state.cursor = #state.input
  state.command_completion_input = nil
  state.command_completion_items = nil
  state.command_completion_force = nil
  state.command_completion_force_input = nil
  state.dirty = true
  return true
end

local function format_command_completion(item, selected, width)
  local marker = selected and "> " or "  "
  local label = tostring(item.label or item.insert or "")

  local desc = item.description or ""

  local label_width = math.min(28, math.max(12, math.floor((tonumber(width) or 80) * 0.36)))
  label = fit_text(label, label_width)
  local padded = label .. string.rep(" ", math.max(1, label_width - display_width(label) + 1))
  local desc_width = math.max(0, (tonumber(width) or 80) - 2 - label_width - 2)
  desc = fit_text(desc, desc_width)

  if selected then
    return ansi.bold(ansi.cyan(marker .. padded)) .. ansi.dim(desc)
  end
  return ansi.dim(marker) .. ansi.cyan(padded) .. ansi.dim(desc)
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
    return EMPTY, EMPTY
  end
  if kind == "tool_result" then
    return EMPTY, EMPTY
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

-- Returns a byte index in `text` such that text:sub(1, idx) fits in
-- `width` display columns. SGR (m-terminated CSI) sequences embedded
-- in the text are skipped over for column counting but kept in place,
-- so colored output still wraps on visual cell boundaries.
local function find_break(text, width)
  local UTF8_CONTINUATION_MASK = 0xc0
  local UTF8_CONTINUATION_TAG = 0x80

  if #text <= width and display_width(text) <= width then
    return #text
  end
  local last_break = nil
  local cells = 0
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    if b == TUI_CONST.byte_esc and text:sub(i + 1, i + 1) == TUI_CONST.char_csi then
      local j = i + 2
      while j <= #text and text:sub(j, j) ~= "m" do
        j = j + 1
      end
      i = j < #text and (j + 1) or (#text + 1)
    else
      if (b & UTF8_CONTINUATION_MASK) ~= UTF8_CONTINUATION_TAG then
        cells = cells + 1
      end
      if cells > width then
        return last_break or (i - 1)
      end
      if b ~= nil and is_space_byte(b) then
        last_break = i
      end
      i = i + 1
    end
  end
  return #text
end

local clear_selection
local set_status

local function new_state(opts)
  local width, height = current_size()
  local viewport_height = inline_viewport_height(height)
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
    busy_next_frame_at = nil,
    busy_started_at = nil,
    busy_kind = nil,
    running = true,
    scroll_offset = 0,
    status_text = nil,
    status_is_error = false,
    show_thinking = tui.show_thinking() == "1",
    show_hardware_cursor = env_bool("PSI_HARDWARE_CURSOR") ~= false,
    width = width,
    height = viewport_height,
    terminal_height = height,
    ui = tui_app.new(),
    renderer = tui_renderer.new({ line_primitive = true }),
    input_layout = default_input_layout(viewport_height),
    tui_caps = caps,
    streaming_assistant_index = nil,
    streaming_thinking_index = nil,
    queue_nav_index = nil,
    entries_version = 0,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    flat_cache_width = nil,
    flat_cache_version = nil,
    flat_cache_lines = nil,
    prompt_history = {},
    history_index = nil,
    history_draft = "",
    history_search_active = false,
    history_search_query = "",
    history_search_draft = "",
    history_search_index = nil,
    command_completion_index = 1,
    command_completion_input = nil,
    command_completion_items = nil,
    dirty = true,
    layout_mode = chat.resolve_mode(opts),
    chat_committed_entry_count = 0,
    chat_live_rows = 0,
    chat_cursor_offset = 0,
    chat_first_paint = false,
  }
  refresh_input_layout(state)
  if tui.run_startup_hooks then
    tui.run_startup_hooks({ opts = opts, state = state })
  end
  return state
end

local function history_add(state, text)
  text = text or ""
  if text == "" then
    return
  end
  if state.prompt_history[#state.prompt_history] == text then
    return
  end
  state.prompt_history[#state.prompt_history + 1] = text
  while #state.prompt_history > 100 do
    table.remove(state.prompt_history, 1)
  end
end

local function history_seed_from_session(state)
  state.prompt_history = {}
  for _, msg in ipairs(session.messages()) do
    if msg.role == "user" and type(msg.text) == "string" and msg.text ~= "" then
      history_add(state, msg.text)
    end
  end
  state.history_index = nil
  state.history_draft = ""
  state.history_search_active = false
  state.history_search_query = ""
  state.history_search_draft = ""
  state.history_search_index = nil
end

local function reset_history_search(state)
  state.history_search_active = false
  state.history_search_query = ""
  state.history_search_draft = ""
  state.history_search_index = nil
end

local function exit_history_browse(state)
  state.history_index = nil
  state.history_draft = ""
  reset_history_search(state)
end

local function history_input_target(state)
  return not state.busy
    and state.editor_mode == "insert"
    and state.selection_anchor == nil
    and state.pending_key == nil
    and not state.history_search_active
end

local function history_up_applicable(state)
  return history_input_target(state) and #state.prompt_history > 0
end

local function history_down_applicable(state)
  return history_input_target(state) and state.history_index ~= nil
end

local function history_up(state)
  if #state.prompt_history == 0 then
    return false
  end
  if state.history_index == nil then
    state.history_draft = state.input or ""
    state.history_index = #state.prompt_history
  elseif state.history_index > 1 then
    state.history_index = state.history_index - 1
  end
  state.input = state.prompt_history[state.history_index] or state.input
  state.cursor = #state.input
  state.dirty = true
  return true
end

local function history_down(state)
  if state.history_index == nil then
    return false
  end
  if state.history_index < #state.prompt_history then
    state.history_index = state.history_index + 1
    state.input = state.prompt_history[state.history_index] or ""
  else
    state.history_index = nil
    state.input = state.history_draft or ""
    state.history_draft = ""
  end
  state.cursor = #state.input
  state.dirty = true
  return true
end

local function history_find_reverse(state, query, before_index)
  local start = math.min(tonumber(before_index) or #state.prompt_history, #state.prompt_history)
  query = tostring(query or "")
  for i = start, 1, -1 do
    local candidate = state.prompt_history[i] or ""
    if query == "" or candidate:find(query, 1, true) then
      return i
    end
  end
  return nil
end

local function history_reverse_search(state)
  if #state.prompt_history == 0 then
    set_status(state, "history empty", true)
    return true
  end
  if not state.history_search_active then
    state.history_search_active = true
    state.history_search_query = state.input or ""
    state.history_search_draft = state.input or ""
    state.history_search_index = #state.prompt_history + 1
  end

  local found =
    history_find_reverse(state, state.history_search_query, (state.history_search_index or 1) - 1)
  if not found then
    set_status(state, "reverse-search: no match", true)
    return true
  end

  state.history_search_index = found
  state.history_index = nil
  state.input = state.prompt_history[found] or ""
  state.cursor = #state.input
  local query = state.history_search_query or ""
  set_status(state, query ~= "" and ("reverse-search: " .. query) or "reverse-search", false)
  state.dirty = true
  return true
end

local function history_search_append(state, text)
  state.history_search_query = (state.history_search_query or "") .. (text or "")
  state.history_search_index = #state.prompt_history + 1
  return history_reverse_search(state, false)
end

local function history_search_backspace(state)
  local query = state.history_search_query or ""
  state.history_search_query = query:sub(1, math.max(0, #query - 1))
  state.history_search_index = #state.prompt_history + 1
  return history_reverse_search(state, false)
end

local function history_search_cancel(state)
  state.input = state.history_search_draft or ""
  state.cursor = #state.input
  reset_history_search(state)
  set_status(state, nil, false)
  state.dirty = true
  return true
end

local function history_search_accept(state)
  reset_history_search(state)
  set_status(state, nil, false)
  state.dirty = true
end

local function invalidate_render_totals(state)
  state.entries_version = (state.entries_version or 0) + 1
  state.total_cache_width = nil
  state.total_cache_version = nil
  state.total_cache_lines = nil
  state.flat_cache_width = nil
  state.flat_cache_version = nil
  state.flat_cache_lines = nil
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

local function clear_busy_input_error(state)
  if state.busy and state.status_is_error then
    set_status(state, "", false)
  end
end

local function add_entry(state, kind, text, title, is_error, tool_call_id)
  local entry = {
    kind = kind,
    text = text or "",
    text_parts = nil,
    title = title,
    is_error = not not is_error,
    tool_call_id = tool_call_id,
  }
  state.entries[#state.entries + 1] = entry
  invalidate_render_totals(state)
  state.dirty = true
  return #state.entries
end

local function add_component_entry(state, kind, component, title, is_error, tool_call_id)
  local index = add_entry(state, kind, "", title, is_error, tool_call_id)
  state.entries[index].component = component
  state.entries[index].render_cache_width = nil
  state.entries[index].render_cache_lines = nil
  return index
end

local function entry_text(entry)
  if not entry then
    return ""
  end
  if entry.text_parts ~= nil and entry.text == nil then
    entry.text = table.concat(entry.text_parts)
    entry.text_parts = entry.text ~= "" and { entry.text } or {}
  end
  return entry.text or ""
end

local function set_entry_text(state, index, text)
  if index == nil or not state.entries[index] then
    return
  end
  local entry = state.entries[index]
  entry.text = text or ""
  entry.text_parts = nil
  entry.component = nil
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
  if text == "" then
    return
  end
  if entry.text_parts == nil then
    local current = entry.text or ""
    entry.text_parts = current ~= "" and { current } or {}
  end
  entry.text_parts[#entry.text_parts + 1] = text
  entry.text = nil
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

local function recolor_tool_call_block(state, tool_call_id, is_error)
  local component_index = find_entry_by_tool_id(state, "tool_execution", tool_call_id)
  local component_entry = component_index and state.entries[component_index] or nil
  if component_entry and component_entry.component then
    component_entry.is_error = not not is_error
    component_entry.render_cache_width = nil
    component_entry.render_cache_lines = nil
    invalidate_render_totals(state)
    state.dirty = true
    return
  end
  local index = find_entry_by_tool_id(state, "tool_call", tool_call_id)
  local entry = index and state.entries[index] or nil
  if not entry then
    return
  end
  local target = ansi.resolve(is_error and PI_STYLE.bg_tool_error or PI_STYLE.bg_tool_success)
  local text = entry_text(entry)
  for _, bg in ipairs({ PI_STYLE.bg_tool_pending, PI_STYLE.bg_tool_success, PI_STYLE.bg_tool_error }) do
    local resolved_bg = ansi.resolve(bg)
    text = text:gsub("\27%[" .. resolved_bg:gsub(";", "%%;") .. "m", "\27[" .. target .. "m")
  end
  set_entry_text(state, index, text)
end

local function finish_streaming_assistant(state)
  local index = state.streaming_assistant_index
  if index ~= nil and state.entries[index] and entry_text(state.entries[index]) == "" then
    remove_entry(state, index)
  end
  state.streaming_assistant_index = nil
end

local function discard_empty_streaming_assistant(state)
  local index = state.streaming_assistant_index
  if index ~= nil and state.entries[index] and entry_text(state.entries[index]) == "" then
    remove_entry(state, index)
    state.streaming_assistant_index = nil
  end
end

local function render_event_plain(event, payload, allow_empty)
  local ok, text = pcall(render.handle_event, event, payload or {})
  if not ok then
    return nil
  end
  -- Keep SGR styling from render.lua's pi-mono tool renderers; the
  -- line sanitizer below preserves SGR and drops layout-affecting CSI.
  text = limit_text(trim_edge_newlines(text or ""))
  if text == "" then
    return allow_empty and "" or nil
  end
  return text
end

local function render_event_details(event, payload)
  local ok, text, replaced = pcall(render.handle_event_details, event, payload or {})
  if not ok then
    return nil, false
  end
  return text, not not replaced
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
  }, true)
  if rendered ~= nil then
    return rendered, result ~= nil and result.ok == false
  end
  return format_tool_result(tool_name or "tool", result)
end

local function new_tool_execution_component(tool_call_id, tool_name, input, opts)
  opts = opts or {}
  local payload = {
    id = tool_call_id or "",
    tool = tool_name or "tool",
    input = input or {},
  }
  if opts.capture ~= false then
    pcall(render.handle_event, "tool-call", payload)
  end
  return tool_execution.new({
    id = payload.id,
    tool = payload.tool,
    input = payload.input,
    frame = payload.id ~= "" and render.lookup_frame(payload.id) or nil,
  })
end

local function update_tool_execution_component(entry, result, is_partial)
  if not entry or not entry.component or type(entry.component.set_result) ~= "function" then
    return false
  end
  entry.component:set_result(records.tool_result_from_alist(result or {}), is_partial)
  entry.is_error = result ~= nil and result.ok == false
  entry.render_cache_width = nil
  entry.render_cache_lines = nil
  return true
end

local function persisted_tool_result_payload(message, content_text)
  message = type(message) == "table" and message or {}
  local payload = safe_decode(content_text, nil)
  if type(payload) ~= "table" then
    payload = {
      ok = not message.isError,
      error = message.isError and content_text or nil,
      output = content_text,
      result = content_text,
    }
    if message.toolName == "read" then
      payload.text = content_text
    end
    return payload
  end
  -- Stored Codex tool results are often JSON strings inside text blocks.
  -- Decode them so replay renders the actual output instead of raw JSON.
  if message.isError then
    payload.ok = false
    payload.error = payload.error or content_text
  elseif payload.ok == nil then
    payload.ok = true
  end
  return payload
end

local function entry_render_lines(state, entry)
  if entry.render_cache_width == state.width and entry.render_cache_lines ~= nil then
    return entry.render_cache_lines
  end

  if entry.component ~= nil and type(entry.component.render) == "function" then
    local rendered = entry.component:render(state.width)
    local lines = {}
    for _, line in ipairs(rendered) do
      lines[#lines + 1] = {
        kind = "ansi",
        text = line,
        raw = strip_ansi(line),
        entry = entry,
      }
    end
    entry.render_cache_width = state.width
    entry.render_cache_lines = lines
    return lines
  end

  if entry.kind == "ansi" then
    local lines = {}
    local text = trim_trailing_newlines(entry_text(entry))
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

  if entry.kind == "assistant" then
    local first_prefix, rest_prefix = entry_prefixes(entry)
    local trimmed = sanitize_terminal_text(trim_trailing_newlines(entry_text(entry)), true)
    entry.markdown_component = entry.markdown_component or tui_markdown.new()
    entry.markdown_component:set_text(trimmed)
    entry.markdown_component:set_prefixes(first_prefix, rest_prefix)
    local rendered = entry.markdown_component:render(state.width)
    local lines = {}
    for _, line in ipairs(rendered) do
      lines[#lines + 1] = {
        kind = "ansi",
        text = line,
        raw = strip_ansi(line),
        entry = entry,
      }
    end
    entry.render_cache_width = state.width
    entry.render_cache_lines = lines
    return lines
  end

  if entry.kind == "user" then
    local trimmed = sanitize_terminal_text(trim_trailing_newlines(entry_text(entry)), true)
    entry.markdown_component = entry.markdown_component or tui_markdown.new()
    entry.markdown_component:set_text(trimmed)
    entry.markdown_component:set_prefixes("", "")
    local rendered = entry.markdown_component:render(math.max(1, state.width - 1))
    local boxed = render_boxed_lines(rendered, state.width, PI_STYLE.bg_user_message, 1, 1)
    local lines = {}
    for _, line in ipairs(boxed) do
      lines[#lines + 1] = {
        kind = "ansi",
        text = line,
        raw = strip_ansi(line),
        entry = entry,
      }
    end
    entry.render_cache_width = state.width
    entry.render_cache_lines = lines
    return lines
  end

  local lines = {}
  local first_prefix, rest_prefix = entry_prefixes(entry)
  local trimmed = sanitize_terminal_text(
    trim_trailing_newlines(entry_text(entry)),
    true,
    entry.kind == "tool_call" or entry.kind == "tool_result",
    entry.kind == "tool_call" or entry.kind == "tool_result"
  )
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

local function flattened_render_lines(state)
  if
    state.flat_cache_width == state.width
    and state.flat_cache_version == state.entries_version
    and state.flat_cache_lines ~= nil
  then
    return state.flat_cache_lines
  end
  local lines = {}
  local total = 0
  for i, entry in ipairs(state.entries) do
    local prev = state.entries[i - 1]
    local same_panel_as_prev = (prev and prev.kind == "tool_call" and entry.kind == "tool_result")
      or (prev and prev.kind == "tool_result" and entry.kind == "tool_result")
    if total > 0 and not same_panel_as_prev then
      total = total + 1
      lines[total] = { kind = "blank", text = "" }
    end
    local entry_lines = entry_render_lines(state, entry)
    for j = 1, #entry_lines do
      total = total + 1
      lines[total] = entry_lines[j]
    end
  end
  state.flat_cache_width = state.width
  state.flat_cache_version = state.entries_version
  state.flat_cache_lines = lines
  state.total_cache_width = state.width
  state.total_cache_version = state.entries_version
  state.total_cache_lines = total
  return lines
end

local function total_rendered_lines(state)
  if
    state.total_cache_width == state.width
    and state.total_cache_version == state.entries_version
    and state.total_cache_lines ~= nil
  then
    return state.total_cache_lines
  end
  local lines = flattened_render_lines(state)
  return #lines
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
            add_component_entry(
              state,
              "tool_execution",
              new_tool_execution_component(
                block.id,
                block.name,
                block.arguments or {},
                { capture = false }
              ),
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
    -- Surface persisted error/aborted assistants so reloaded sessions show
    -- the same context the live turn rendered (parity with pi-mono's
    -- assistant-message.ts errorMessage rendering).
    local persisted = body and body.message
    if type(persisted) == "table" then
      local stop = persisted.stopReason
      local err = persisted.errorMessage
      if (stop == "error" or stop == "aborted") and type(err) == "string" and err ~= "" then
        if err ~= "Request was aborted" then
          add_entry(state, "error", err)
        end
      end
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
    local payload = persisted_tool_result_payload(message, content_text)
    local tool_name = message.toolName or payload.tool
    local component_index = find_entry_by_tool_id(state, "tool_execution", message.toolCallId)
    if component_index ~= nil and state.entries[component_index] then
      local entry = state.entries[component_index]
      entry.title = tool_name
      update_tool_execution_component(entry, payload, false)
      invalidate_render_totals(state)
      return
    end
    local result_text, is_error = tool_result_text(message.toolCallId, tool_name, payload)
    recolor_tool_call_block(state, message.toolCallId, is_error)
    if result_text and result_text ~= "" then
      add_entry(state, "tool_result", result_text, tool_name, is_error, message.toolCallId)
    end
    return
  end

  if msg.role == "compaction-summary" then
    add_entry(state, "compaction", msg.text or "")
    return
  end

  if msg.role == "branch-summary" then
    add_entry(state, "compaction", msg.text or "")
    return
  end

  if type(msg.text) == "string" and msg.text ~= "" then
    add_entry(state, "info", msg.text)
  end
end

local function rebuild_from_session(state, messages)
  state.entries = {}
  state.streaming_assistant_index = nil
  state.streaming_thinking_index = nil
  state.show_thinking = tui.show_thinking() == "1"
  invalidate_render_totals(state)
  for _, msg in ipairs(messages or session.messages()) do
    add_session_entry(state, msg)
  end
  if messages == nil then
    history_seed_from_session(state)
  end
  state.scroll_offset = 0
  state.chat_committed_entry_count = 0
  -- Keep the previous live-region anchor until chat.redraw erases it.  A
  -- reset here makes the next redraw clear from the input cursor instead,
  -- leaving the old input border above resumed session output.
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
    -- render.lua's pi-mono renderers emit fully styled SGR text already
    -- (bold title, accent path, muted output, colored background).
    -- Pass through unchanged so we don't double-paint over our own colors.
    return line.text
  end
  if line.kind == "btw" then
    return ansi.yellow(line.text)
  end
  if line.kind == "tool_result" then
    return line.text
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
  local lines = prelude.array(count)
  local flat = flattened_render_lines(state)
  for i = 1, count do
    lines[i] = flat[first_line + i - 1]
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
  local pending_anchor_row = status_visible and (status_row - 1) or (input_start_row - 1)
  local max_pending_rows = math.max(0, pending_anchor_row - transcript_start)
  local pending_lines = pending_queue_lines(state.width or DEFAULT_WIDTH, max_pending_rows)
  local pending_rows = #pending_lines
  local pending_start_row = pending_rows > 0 and (pending_anchor_row - pending_rows + 1) or nil
  local command_completions = active_command_completions(state)
  local completion_anchor_row = pending_rows > 0 and (pending_start_row - 1) or pending_anchor_row
  local max_completion_rows = math.max(0, completion_anchor_row - transcript_start)
  local command_completion_rows =
    math.min(#command_completions, MAX_COMMAND_COMPLETION_ROWS, max_completion_rows)
  local command_completion_first = 1
  if command_completion_rows > 0 then
    command_completion_first = (state.command_completion_index or 1) - command_completion_rows + 1
    command_completion_first = clamp(
      command_completion_first,
      1,
      math.max(1, #command_completions - command_completion_rows + 1)
    )
  end
  local command_completion_start = completion_anchor_row - command_completion_rows + 1
  local transcript_end = completion_anchor_row - command_completion_rows
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
    pending_lines = pending_lines,
    pending_rows = pending_rows,
    pending_start_row = pending_start_row,
    status_visible = status_visible,
    status_row = status_row,
    footer_row = footer_row,
    input_start_row = input_start_row,
    command_completions = command_completions,
    command_completion_rows = command_completion_rows,
    command_completion_first = command_completion_first,
    command_completion_start = command_completion_start,
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

local function style_input_prefix(prefix, is_first)
  if is_first then
    return ansi.cyan(prefix)
  end
  return ansi.dim(prefix)
end

local function style_input_text(text)
  return text
end

local function style_input_cursor(text)
  return ansi.color("4", text == "" and " " or text)
end

local function style_input_fill(width)
  return string.rep(" ", math.max(0, width))
end

local function style_input_border(width)
  return ansi.color(PI_STYLE.border, string.rep("─", math.max(0, width)))
end

local function input_box_line(content, width)
  content = content or ""
  width = math.max(1, tonumber(width) or 1)
  return content .. style_input_fill(width - display_width(content), "body")
end

local render_input_text
local render_input_text_with_cursor
local input_line_selected

local function ensure_frame_components(state)
  if state.frame_components ~= nil then
    return state.frame_components
  end
  state.ui = state.ui or tui_app.new()
  local frame = {
    workspace = tui_component.block({}, { pad = true }),
    transcript = tui_component.block({}, { pad = true }),
    completions = tui_component.block({}, { pad = true }),
    pending = tui_component.block({}, { pad = true }),
    status = tui_component.block({}, { pad = true }),
    input = tui_component.block({}, { pad = true }),
    footer = tui_component.block({}, { pad = true }),
  }
  frame.root = tui_component.container({
    frame.workspace,
    frame.transcript,
    frame.completions,
    frame.pending,
    frame.status,
    frame.input,
    frame.footer,
  })
  state.ui:add_child(frame.root)
  state.frame_components = frame
  return frame
end

local function redraw(state)
  if state.layout_mode == chat.CHAT then
    return chat.redraw(state)
  end
  local terminal_width, terminal_height = current_size()
  state.width = terminal_width
  state.terminal_height = terminal_height
  state.height = inline_viewport_height(terminal_height)
  local rows = layout_rows(state)
  local total_lines = total_rendered_lines(state)
  local max_scroll = math.max(0, total_lines - rows.transcript_height)
  local status_arg
  local status_text = ""
  local cwd
  local frame = ensure_frame_components(state)
  local frame_width

  state.scroll_offset = clamp(state.scroll_offset, 0, max_scroll)

  if state.force_physical_clear then
    psi.tui_clear(true)
    tui_renderer.reset(state.renderer)
    if state.ui and type(state.ui.request_render) == "function" then
      state.ui:request_render(true)
    end
  end
  frame_width = math.max(1, state.width)
  cwd = psi.cwd() or "."
  frame.workspace:set_lines({
    tui.compose_bar(tui.workspace_bar_for_width(cwd, frame_width), frame_width),
  })

  local first_line = total_lines - rows.transcript_height - state.scroll_offset + 1
  if first_line < 1 then
    first_line = 1
  end
  local transcript_lines = build_render_window(state, first_line, rows.transcript_height)
  local transcript_component_lines = {}
  for i = 0, rows.transcript_height - 1 do
    local line = transcript_lines[i + 1]
    transcript_component_lines[#transcript_component_lines + 1] = line and style_line(line) or ""
  end
  frame.transcript:set_lines(transcript_component_lines)

  if rows.command_completion_rows > 0 then
    local completion_lines = {}
    for i = 1, rows.command_completion_rows do
      local item_index = (rows.command_completion_first or 1) + i - 1
      local item = rows.command_completions[item_index]
      local selected = item_index == (state.command_completion_index or 1)
      completion_lines[#completion_lines + 1] = tui_text.pad_line(
        item and format_command_completion(item, selected, frame_width) or "",
        frame_width
      )
    end
    frame.completions:set_lines(completion_lines)
  else
    frame.completions:set_lines({})
  end
  frame.pending:set_lines(rows.pending_lines or {})

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
    show_queue_in_status = false,
  }

  if state.status_text ~= nil then
    status_text = state.status_is_error and ansi.bold(ansi.red(state.status_text))
      or ansi.dim(state.status_text)
  elseif state.busy then
    status_text = tui.render_busy_status(
      state.busy_label or "working",
      state.busy_phase,
      status_arg.elapsed_seconds,
      state.busy_tick
    )
  end
  if rows.status_visible then
    frame.status:set_lines({ status_text })
  else
    frame.status:set_lines({})
  end

  local input_width = frame_width
  local input_component_lines = {
    style_input_border(input_width),
  }
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
      input_text = apply_bg_line(PI_STYLE.bg_selected, input_box_line(prefix .. text, input_width))
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
    input_component_lines[#input_component_lines + 1] = input_text
  end
  input_component_lines[#input_component_lines + 1] = style_input_border(input_width)
  frame.input:set_lines(input_component_lines)

  frame.footer:set_lines({ tui.compose_bar(tui.status_bar(status_arg) or "", frame_width) })
  local visible_cursor_line = rows.cursor_line - rows.input_first_line + 1
  local cursor_prefix = rows.cursor_line == 1 and state.input_layout.prefix_first
    or state.input_layout.prefix_rest
  local cursor_row = rows.input_start_row + visible_cursor_line
  local cursor_col = display_width(cursor_prefix) + rows.cursor_col + 1
  cursor_row = clamp(cursor_row, rows.input_start_row + 1, rows.input_start_row + rows.input_rows)
  cursor_col = clamp(cursor_col, 1, math.max(1, state.width))

  local frame_lines = state.ui:render(frame_width, math.max(1, state.height or 1))
  local frame_height = #frame_lines
  local viewport_top = math.max(1, (state.terminal_height or state.height) - frame_height + 1)
  local force_full = state.force_physical_clear
  if state.ui and type(state.ui.consume_force_full) == "function" then
    force_full = force_full or state.ui:consume_force_full()
  end
  state.renderer = state.renderer:render({
    width = frame_width,
    height = frame_height,
    top = viewport_top,
    lines = frame_lines,
    cursor = {
      row = cursor_row,
      col = cursor_col,
      visible = state.show_hardware_cursor,
    },
    force_full = force_full,
  })
  state.force_physical_clear = false
  if state.ui and type(state.ui.consume_dirty) == "function" then
    state.ui:consume_dirty()
  end
  state.dirty = false
end

-- Chat mode renderer.
--
-- Lays the conversation out in the terminal's primary screen so it ends up
-- in native scrollback (mouse wheel, shell scrollback). Each redraw:
--
--   1. Erases the previous "live region" (last entry being mutated, status,
--      input box) by moving the cursor up state.chat_live_rows lines and
--      clearing to end of screen.
--   2. Appends any newly-completed entries to scrollback with plain
--      newlines so the terminal scrolls them naturally.
--   3. Repaints the live region in place. The bottom-most live row stays
--      visible; previous content scrolls up out of view.
--
-- The "committed" boundary is always all-but-the-last entry: the last
-- entry may still be streaming, so we keep it in the mutable region.
function chat.redraw(state)
  state.width, state.height = current_size()
  state.scroll_offset = 0
  refresh_input_layout(state)

  local frame_width = math.max(1, state.width - 1)
  local out = {}
  local function panel_join(prev, entry)
    return (prev and prev.kind == "tool_call" and entry.kind == "tool_result")
      or (prev and prev.kind == "tool_result" and entry.kind == "tool_result")
  end

  -- 1. Erase previous live region or prepare clean line for first paint.
  --
  -- After the previous redraw, the cursor sits at the prompt row INSIDE
  -- the live region (state.chat_cursor_offset rows below the region's
  -- top). To re-anchor we go up that offset to reach the top, then
  -- erase from there to end of screen. Using chat_live_rows here would
  -- overshoot and clobber whatever's above (the user's shell prompt and
  -- any terminal scrollback).
  if state.chat_first_paint then
    local up = tonumber(state.chat_cursor_offset) or 0
    if up > 0 then
      out[#out + 1] = "\27[" .. up .. "F"
    else
      out[#out + 1] = "\r"
    end
    out[#out + 1] = "\27[J"
  else
    out[#out + 1] = "\r\27[J"
    state.chat_first_paint = true
  end

  -- 2. Commit entries that are no longer the last entry.
  if state.chat_committed_entry_count > #state.entries then
    state.chat_committed_entry_count = #state.entries
  end
  -- Raw mode disables OPOST so "\n" is bare LF: cursor moves down but
  -- stays at the current column. Use "\r\n" everywhere to anchor each
  -- new line at column 1, otherwise the next line gets emitted starting
  -- where the previous one ended.
  local committed_target = math.max(0, #state.entries - 1)
  while state.chat_committed_entry_count < committed_target do
    local idx = state.chat_committed_entry_count + 1
    local entry = state.entries[idx]
    local prev = state.entries[idx - 1]
    local next_entry = state.entries[idx + 1]
    if idx > 1 and not panel_join(prev, entry) then
      out[#out + 1] = "\r\n"
    end
    for _, line in ipairs(entry_render_lines(state, entry)) do
      out[#out + 1] = style_line(line)
      out[#out + 1] = "\27[0m\r\n"
    end
    if entry.kind == "tool_result" and (not next_entry or next_entry.kind ~= "tool_result") then
      out[#out + 1] = ansi.yellow("╰─")
      out[#out + 1] = "\27[0m\r\n"
    end
    state.chat_committed_entry_count = idx
  end

  -- 3. Build live region: last entry (if any) + status + input box + footer.
  local live_lines = {}
  if #state.entries > 0 then
    local idx = #state.entries
    local entry = state.entries[idx]
    local prev = state.entries[idx - 1]
    if state.chat_committed_entry_count >= 1 and not panel_join(prev, entry) then
      live_lines[#live_lines + 1] = ""
    end
    for _, line in ipairs(entry_render_lines(state, entry)) do
      live_lines[#live_lines + 1] = style_line(line)
    end
    if entry.kind == "tool_result" then
      live_lines[#live_lines + 1] = ansi.yellow("╰─")
    end
  end

  local status_arg = {
    model = state.model and state.model.id or state.opts.model,
    provider = state.model and state.model.provider or nil,
    context_window = state.model and state.model.context_window or nil,
    busy = state.busy,
    busy_label = state.busy_label,
    elapsed_seconds = state.busy_started_at and (os.time() - state.busy_started_at) or 0,
    busy_phase = state.busy_phase,
    scroll = 0,
    editor_mode = state.editor_mode,
    selection_kind = state.selection_kind,
    show_queue_in_status = false,
  }
  local status_text = nil
  if state.status_text ~= nil then
    status_text = state.status_is_error and ansi.bold(ansi.red(state.status_text))
      or ansi.dim(state.status_text)
  elseif state.busy then
    status_text = tui.render_busy_status(
      state.busy_label or "working",
      state.busy_phase,
      status_arg.elapsed_seconds,
      state.busy_tick
    )
  end
  for _, line in ipairs(pending_queue_lines(frame_width)) do
    live_lines[#live_lines + 1] = line
  end

  if status_text ~= nil then
    live_lines[#live_lines + 1] = status_text
  end

  local input_lines, cursor_line, cursor_col = build_input_lines(state)
  local input_max = input_max_rows(state)
  local input_rows_n = math.max(1, math.min(#input_lines, input_max))
  local input_first_line = 1
  if cursor_line > input_rows_n then
    input_first_line = cursor_line - input_rows_n + 1
  end
  if input_first_line + input_rows_n - 1 > #input_lines then
    input_first_line = #input_lines - input_rows_n + 1
  end
  local input_width = frame_width
  local input_box_top_idx = #live_lines + 1
  live_lines[#live_lines + 1] = style_input_border(input_width)
  for i = 0, input_rows_n - 1 do
    local line_index = input_first_line + i
    local line = input_lines[line_index]
    local prefix = line_index == 1 and state.input_layout.prefix_first
      or state.input_layout.prefix_rest
    local text = ""
    if line ~= nil then
      text = render_input_text(state, line)
    end
    local rendered
    if input_line_selected and input_line_selected(state, line) then
      rendered = ansi.color("7", input_box_line(prefix .. text, input_width))
    else
      rendered = input_box_line(
        style_input_prefix(prefix, line_index == 1)
          .. (
            line and render_input_text_with_cursor(state, line, line_index == cursor_line)
            or style_input_text(text)
          ),
        input_width
      )
    end
    live_lines[#live_lines + 1] = rendered
  end
  live_lines[#live_lines + 1] = style_input_border(input_width)
  live_lines[#live_lines + 1] = tui.compose_bar(tui.status_bar(status_arg) or "", frame_width)

  -- 4. Emit live region inside synchronized output, then position cursor.
  out[#out + 1] = "\27[?2026h\27[?25l"
  for i, line in ipairs(live_lines) do
    out[#out + 1] = line
    out[#out + 1] = "\27[0m"
    if i < #live_lines then
      out[#out + 1] = "\r\n"
    end
  end

  local visible_cursor_line = cursor_line - input_first_line + 1
  local cursor_target_idx = input_box_top_idx + visible_cursor_line
  local rows_up = #live_lines - cursor_target_idx
  local cursor_prefix = cursor_line == 1 and state.input_layout.prefix_first
    or state.input_layout.prefix_rest
  local cursor_col_n = display_width(cursor_prefix) + cursor_col + 1
  cursor_col_n = clamp(cursor_col_n, 1, math.max(1, state.width - 1))
  if rows_up > 0 then
    out[#out + 1] = "\27[" .. rows_up .. "F"
  else
    out[#out + 1] = "\r"
  end
  out[#out + 1] = "\27[" .. cursor_col_n .. "G"
  out[#out + 1] = "\27[?25h\27[?2026l"

  state.chat_live_rows = #live_lines
  state.chat_cursor_offset = math.max(0, cursor_target_idx - 1)
  if type(psi.tui_write) == "function" then
    psi.tui_write(table.concat(out))
  end
  state.dirty = false
end

local function byte_at(text, pos)
  if pos < 0 or pos >= #text then
    return nil
  end
  return text:byte(pos + 1)
end

function M._is_punctuation_byte(b)
  return b == 33
    or b == 34
    or b == 35
    or b == 36
    or b == 37
    or b == 38
    or b == 39
    or b == 40
    or b == 41
    or b == 42
    or b == 43
    or b == 44
    or b == 45
    or b == 46
    or b == 47
    or b == 58
    or b == 59
    or b == 60
    or b == 61
    or b == 62
    or b == 63
    or b == 64
    or b == 91
    or b == 92
    or b == 93
    or b == 94
    or b == 96
    or b == 123
    or b == 124
    or b == 125
    or b == 126
end

function M._word_backward_pos(text, cursor)
  text = text or ""
  local pos = clamp(tonumber(cursor) or 0, 0, #(text or ""))
  while pos > 0 do
    local b = byte_at(text, pos - 1)
    if b == nil or not is_space_byte(b) then
      break
    end
    pos = pos - 1
  end
  if pos == 0 then
    return pos
  end
  local punctuation = M._is_punctuation_byte(byte_at(text, pos - 1))
  while pos > 0 do
    local b = byte_at(text, pos - 1)
    if b == nil or is_space_byte(b) or M._is_punctuation_byte(b) ~= punctuation then
      break
    end
    pos = pos - 1
  end
  return pos
end

function M._word_forward_pos(text, cursor)
  text = text or ""
  local pos = clamp(tonumber(cursor) or 0, 0, #(text or ""))
  while pos < #text do
    local b = byte_at(text, pos)
    if b == nil or not is_space_byte(b) then
      break
    end
    pos = pos + 1
  end
  if pos >= #text then
    return pos
  end
  local punctuation = M._is_punctuation_byte(byte_at(text, pos))
  while pos < #text do
    local b = byte_at(text, pos)
    if b == nil or is_space_byte(b) or M._is_punctuation_byte(b) ~= punctuation then
      break
    end
    pos = pos + 1
  end
  return pos
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
  clear_busy_input_error(state)
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
  clear_busy_input_error(state)
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
  if state.show_hardware_cursor then
    return style_input_text(before)
      .. tui_renderer.cursor_marker()
      .. style_input_text(cell .. after)
  end
  return style_input_text(before)
    .. tui_renderer.cursor_marker()
    .. style_input_cursor(cell)
    .. style_input_text(after)
end

local function insert_text(state, text)
  clear_busy_input_error(state)
  exit_history_browse(state)
  state.input = state.input:sub(1, state.cursor) .. text .. state.input:sub(state.cursor + 1)
  state.cursor = state.cursor + #text
  state.dirty = true
end

local function delete_backward(state)
  exit_history_browse(state)
  if state.cursor == 0 or #state.input == 0 then
    return
  end
  clear_busy_input_error(state)
  state.input = state.input:sub(1, state.cursor - 1) .. state.input:sub(state.cursor + 1)
  state.cursor = state.cursor - 1
  state.dirty = true
end

local function delete_forward(state)
  exit_history_browse(state)
  if state.cursor >= #state.input then
    return
  end
  clear_busy_input_error(state)
  state.input = state.input:sub(1, state.cursor) .. state.input:sub(state.cursor + 2)
  state.dirty = true
end

local function delete_word_backward(state)
  exit_history_browse(state)
  if state.cursor == 0 then
    return
  end
  local start = M._word_backward_pos(state.input, state.cursor)
  clear_busy_input_error(state)
  state.input = state.input:sub(1, start) .. state.input:sub(state.cursor + 1)
  state.cursor = start
  state.dirty = true
end

local function delete_word_forward(state)
  exit_history_browse(state)
  if state.cursor >= #state.input then
    return
  end
  local finish = M._word_forward_pos(state.input, state.cursor)
  clear_busy_input_error(state)
  state.input = state.input:sub(1, state.cursor) .. state.input:sub(finish + 1)
  state.dirty = true
end

local function move_word_backward(state)
  state.cursor = M._word_backward_pos(state.input, state.cursor)
  state.dirty = true
end

local function move_word_forward(state)
  state.cursor = M._word_forward_pos(state.input, state.cursor)
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
  clear_busy_input_error(state)
  exit_history_browse(state)
  state.input = state.input:sub(1, state.cursor)
  state.dirty = true
end

local function kill_to_start(state)
  exit_history_browse(state)
  if state.cursor == 0 then
    return
  end
  clear_busy_input_error(state)
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
      local label = item and item.kind == "steering" and "Steering" or "Follow-up"
      pieces[#pieces + 1] = label .. ": " .. text
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
  if line == "/queue" or line:match("^/queue%s+") then
    local action = commands.handle(line)
    if action ~= nil then
      return action
    end
    return {
      kind = "print",
      payload = "usage: /queue [list|state|modes|mode|steer|follow-up|clear|drop|edit]",
    }
  end
  if line:match("^/btw%s+") then
    return { kind = "btw" }
  end
  return nil
end

local function queue_current_input(state, line, kind)
  local count = agent.pending_message_count()
  if
    state.queue_nav_index ~= nil
    and state.queue_nav_index >= 1
    and state.queue_nav_index <= count
  then
    if agent.replace_pending(state.queue_nav_index, line) then
      state.queue_nav_index = nil
      set_status(state, "", false)
      state.dirty = true
      return
    end
  end
  kind = kind == "follow-up" and "follow-up" or "steering"
  local ok
  if kind == "follow-up" then
    ok = agent.queue_follow_up(line)
  else
    ok = agent.queue_steering(line)
  end
  if ok then
    history_add(state, line)
    state.queue_nav_index = nil
    set_status(state, "", false)
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

local function restore_queued_message(state, opts)
  opts = opts or {}
  local count = agent.pending_message_count()
  if count == 0 then
    state.queue_nav_index = nil
    if not opts.quiet then
      set_status(state, "No queued messages to restore", false)
    end
    return 0
  end
  local messages = {}
  for _, item in ipairs(agent.pending_messages() or {}) do
    messages[#messages + 1] = item.text or ""
  end
  if #messages == 0 then
    state.queue_nav_index = nil
    if not opts.quiet then
      set_status(state, "No queued messages to restore", false)
    end
    return 0
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
  if opts.status_text ~= nil then
    set_status(state, opts.status_text, false)
  elseif not opts.quiet then
    set_status(
      state,
      "Restored "
        .. tostring(#messages)
        .. " queued message"
        .. (#messages == 1 and "" or "s")
        .. " to editor",
      false
    )
  end
  state.dirty = true
  return #messages
end

local function abort_active_turn(state)
  local restored = 0
  if agent.pending_message_count() > 0 then
    restored = restore_queued_message(state, { quiet = true })
  end
  psi.abort_trigger()
  if restored == 0 then
    set_status(state, "aborting...", false)
    state.dirty = true
  end
end

local function open_external_editor(state)
  local editor = os.getenv("VISUAL") or os.getenv("EDITOR")
  if type(editor) ~= "string" or editor == "" then
    set_status(state, "No editor configured. Set VISUAL or EDITOR.", true)
    state.dirty = true
    return
  end
  if type(psi.tui_external_editor) ~= "function" then
    set_status(state, "external editor unavailable", true)
    state.dirty = true
    return
  end
  local path = psi.tempfile_path and psi.tempfile_path("psi-editor-") or nil
  if type(path) ~= "string" or path == "" then
    set_status(state, "failed to create editor temp file", true)
    state.dirty = true
    return
  end
  if not psi.file_write(path, state.input or "") then
    set_status(state, "failed to write editor temp file", true)
    state.dirty = true
    return
  end
  set_status(state, "editing in " .. editor, false)
  redraw(state)
  local status, err = psi.tui_external_editor(path, editor)
  state.force_physical_clear = true
  if status == nil then
    set_status(state, tostring(err or "external editor failed"), true)
    state.dirty = true
    return
  end
  if tonumber(status) == 0 then
    local updated = psi.read_file(path)
    updated = (updated or ""):gsub("\n$", "")
    state.input = updated
    state.cursor = #state.input
    clear_selection(state)
    state.block_edit = nil
    state.editor_mode = "insert"
    set_status(state, "", false)
  else
    set_status(state, "external editor exited with status " .. tostring(status), true)
  end
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
  local override_text, replaced = render_event_details("tool-call", {
    id = tool_call_id or "",
    tool = tool_name or "tool",
    input = input or {},
  })
  if replaced then
    if override_text ~= nil and override_text ~= "" then
      add_entry(state, "tool_call", override_text, tool_name, false, tool_call_id)
    end
    scroll_anchor_after(state, before)
    return
  end
  add_component_entry(
    state,
    "tool_execution",
    new_tool_execution_component(tool_call_id, tool_name, input, { capture = false }),
    tool_name,
    false,
    tool_call_id
  )
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
  local index = find_entry_by_tool_id(state, "tool_execution", tool_call_id)
  if index ~= nil and state.entries[index] and state.entries[index].component then
    local entry = state.entries[index]
    local text
    if type(payload) == "table" and payload.psi_progress_replace == true then
      text = M._live_progress.update(entry, tostring(payload.text or ""), true)
    else
      text = M._live_progress.update(entry, chunk, false)
    end
    update_tool_execution_component(entry, { ok = true, output = text }, true)
    invalidate_render_totals(state)
    state.dirty = true
    scroll_anchor_after(state, before)
    return
  end
  index = find_entry_by_tool_id(state, "tool_result", tool_call_id)
  if index == nil then
    index = add_entry(state, "tool_result", "", nil, false, tool_call_id)
  end
  if type(payload) == "table" and payload.psi_progress_replace == true then
    local entry = state.entries[index]
    if entry then
      set_entry_text(
        state,
        index,
        M._live_progress.update(entry, tostring(payload.text or ""), true)
      )
    end
  else
    local entry = state.entries[index]
    if entry then
      set_entry_text(state, index, M._live_progress.update(entry, chunk, false))
    end
  end
  scroll_anchor_after(state, before)
end

local function observer_tool_result(state, tool_call_id, tool_name, output_json)
  local before = scroll_anchor_before(state)
  local result = safe_decode(output_json, nil)
  local override_text, replaced = render_event_details("tool-result", {
    id = tool_call_id or "",
    tool = tool_name or "tool",
    result = result or {},
  })
  if replaced then
    local index = find_entry_by_tool_id(state, "tool_execution", tool_call_id)
      or find_entry_by_tool_id(state, "tool_result", tool_call_id)
    if index ~= nil and state.entries[index] then
      if override_text ~= nil and override_text ~= "" then
        local entry = state.entries[index]
        entry.kind = "tool_result"
        entry.title = tool_name
        entry.is_error = result ~= nil and result.ok == false
        entry.progress_lines = nil
        entry.progress_partial = nil
        entry.progress_total_lines = nil
        set_entry_text(state, index, override_text or "")
      else
        remove_entry(state, index)
      end
    elseif override_text ~= nil and override_text ~= "" then
      add_entry(
        state,
        "tool_result",
        override_text,
        tool_name,
        result ~= nil and result.ok == false,
        tool_call_id
      )
    end
    scroll_anchor_after(state, before)
    return
  end
  local component_index = find_entry_by_tool_id(state, "tool_execution", tool_call_id)
  if component_index ~= nil and state.entries[component_index] then
    local entry = state.entries[component_index]
    entry.title = tool_name
    entry.progress_lines = nil
    entry.progress_partial = nil
    entry.progress_total_lines = nil
    update_tool_execution_component(entry, result, false)
    invalidate_render_totals(state)
    state.dirty = true
    scroll_anchor_after(state, before)
    return
  end
  local text, is_error = tool_result_text(tool_call_id, tool_name, result)
  local index = find_entry_by_tool_id(state, "tool_result", tool_call_id)
  local has_text = text ~= nil and text ~= ""

  recolor_tool_call_block(state, tool_call_id, is_error)

  if index ~= nil and state.entries[index] then
    if has_text then
      local entry = state.entries[index]
      entry.title = tool_name
      entry.is_error = not not is_error
      entry.progress_lines = nil
      entry.progress_partial = nil
      entry.progress_total_lines = nil
      set_entry_text(state, index, text or "")
    else
      remove_entry(state, index)
    end
  elseif has_text then
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

local function add_nonstreamed_assistant_reply(state, reply, assistant_streamed)
  if assistant_streamed or type(reply) ~= "string" or reply == "" then
    return false
  end
  add_entry(state, "assistant", reply)
  return true
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
    local detail = reply ~= nil and reply ~= "" and tostring(reply) or "agent turn failed"
    add_entry(state, "error", detail)
    set_status(state, detail, true)
    fire_turn_event(state, "after-turn", after_turn_payload("", false))
    session.save()
    return false
  end

  if ok then
    add_nonstreamed_assistant_reply(state, reply, assistant_streamed)
  end
  fire_turn_event(state, "after-turn", after_turn_payload(reply, assistant_streamed))

  if not ok then
    if reply == "aborted" then
      set_status(state, "aborted", false)
    else
      local detail = (reply ~= nil and reply ~= "") and tostring(reply) or "provider request failed"
      add_entry(state, "error", detail)
      set_status(state, detail, true)
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
  state.busy_next_frame_at = now_ms() + TUI_CONST.busy_animation_interval_ms
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
      abort_check = psi.is_aborted,
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
    local detail = (summary ~= nil and summary ~= "") and tostring(summary)
      or "failed to compact session"
    set_status(state, detail, true)
    add_entry(state, "error", detail)
  end

  state.busy = false
  state.busy_kind = nil
  state.busy_label = nil
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_next_frame_at = nil
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
  state.busy_next_frame_at = nil
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
  state.busy_next_frame_at = now_ms() + TUI_CONST.busy_animation_interval_ms
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

local choose_session_tui

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

  if action.kind == "tree" then
    local payload = action.payload or {}
    state.busy = true
    state.busy_kind = "tree"
    state.busy_label = payload.summarize and "summarizing branch" or "switching branch"
    state.busy_phase = 0
    state.busy_tick = 0
    state.busy_next_frame_at = now_ms() + TUI_CONST.busy_animation_interval_ms
    state.busy_started_at = os.time()
    psi.abort_reset()
    set_status(state, state.busy_label, false)
    redraw(state)

    local ran, ok, result = xpcall(function()
      return agent.run_tree({
        target = payload.target,
        summarize = payload.summarize,
        custom_instructions = payload.custom_instructions,
        model = state.opts.model,
        max_tokens = state.opts.max_tokens,
        thinking_level = state.opts.thinking_level,
        reasoning_effort = state.opts.reasoning_effort,
        abort_check = psi.is_aborted,
      })
    end, debug.traceback)

    if not ran then
      ok = false
      result = result or "tree navigation failed"
    end
    if ok then
      local saved, err = session.save()
      if not saved then
        set_status(state, "failed to save session: " .. tostring(err), true)
      else
        rebuild_from_session(state)
        add_entry(state, "info", "active branch leaf: " .. tostring(result.target))
        set_status(state, "branch switched", false)
      end
    else
      add_entry(state, "error", "tree navigation failed: " .. tostring(result))
      set_status(state, "tree navigation failed", true)
    end

    reset_busy(state)
    state.dirty = true
    redraw(state)
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

  if action.kind == "set-theme" then
    local ok, err = false, "theme unavailable"
    if psi.theme and psi.theme.use then
      ok, err = psi.theme.use(action.payload)
    end
    if not ok then
      set_status(state, "theme: " .. tostring(err or "unknown theme"), true)
      return true
    end
    add_entry(state, "info", "theme set to " .. tostring(action.payload))
    state.dirty = true
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

  if action.kind == "resume-picker" then
    local selected = choose_session_tui(session.list_sessions(psi.cwd()))
    if not selected then
      set_status(state, "no session selected", true)
      return true
    end
    local ok, err = session.load(selected)
    if not ok then
      set_status(state, "resume failed: " .. tostring(err), true)
      return true
    end
    state.opts.session_file = selected
    context.reset_usage()
    rebuild_from_session(state)
    add_entry(
      state,
      "info",
      "resumed "
        .. tostring(selected)
        .. " ("
        .. tostring(psi.session_message_count())
        .. " messages)"
    )
    set_status(state, "", false)
    return true
  end

  if action.kind == "name" then
    session.set_display_name(action.payload)
    session.save()
    add_entry(state, "info", "name set to '" .. tostring(action.payload) .. "'")
    set_status(state, "", false)
    return true
  end

  set_status(state, "unknown command", true)
  return true
end

local function submit(state, queue_kind)
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
  exit_history_browse(state)

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
    queue_current_input(state, line, queue_kind)
    return
  end

  if line:sub(1, 1) == "/" then
    local handled, expanded = handle_command(state, line)
    if handled then
      return
    end
    line = expanded or ""
  end

  history_add(state, line)
  add_entry(state, "user", line)
  state.streaming_assistant_index = add_entry(state, "assistant", "")
  state.show_thinking = tui.show_thinking() == "1"
  state.scroll_offset = 0
  state.busy = true
  state.busy_kind = "agent"
  state.busy_label = tui.pick_busy_status() or "working"
  state.busy_phase = 0
  state.busy_tick = 0
  state.busy_next_frame_at = now_ms() + TUI_CONST.busy_animation_interval_ms
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
  state.busy_next_frame_at = nil
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
    submit(state, arg)
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
  if action == "history-search" then
    if not state.busy then
      history_reverse_search(state, true)
    end
    return
  end
  if action == "scroll" then
    if state.layout_mode == chat.CHAT then
      -- Terminal handles scrollback natively. Keep history navigation though.
      if arg == "line-up" and history_up_applicable(state) then
        history_up(state)
      elseif arg == "line-down" and history_down_applicable(state) then
        history_down(state)
      end
      return
    end
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
      if history_up_applicable(state) and history_up(state) then
        return
      end
      scroll_by(state, 1)
    elseif arg == "line-down" then
      if history_down_applicable(state) and history_down(state) then
        return
      end
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
    abort_active_turn(state)
    return
  end
  if action == "external-editor" then
    open_external_editor(state)
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
  if state.ui and type(state.ui.dispatch_key) == "function" and state.ui:dispatch_key(event) then
    state.dirty = true
    return
  end
  if state.history_search_active then
    if event.key == "ctrl-r" then
      history_reverse_search(state, true)
      return
    end
    if event.key == "escape" then
      history_search_cancel(state)
      return
    end
    if event.key == "backspace" then
      history_search_backspace(state)
      return
    end
    if event.key == "enter" then
      history_search_accept(state)
    elseif type(event.text) == "string" and event.text ~= "" then
      history_search_append(state, event.text)
      return
    else
      history_search_accept(state)
    end
  end

  local completions = active_command_completions(state)
  if
    #completions == 0
    and event.key == "tab"
    and not state.busy
    and state.cursor == #(state.input or "")
  then
    state.command_completion_force = true
    state.command_completion_force_input = state.input
    completions = active_command_completions(state)
    if #completions > 0 then
      state.command_completion_index = 1
      state.dirty = true
    end
    return
  end
  if #completions > 0 then
    if event.key == "up" then
      state.command_completion_index = (state.command_completion_index or 1) - 1
      if state.command_completion_index < 1 then
        state.command_completion_index = #completions
      end
      state.dirty = true
      return
    end
    if event.key == "down" then
      state.command_completion_index = (state.command_completion_index or 1) + 1
      if state.command_completion_index > #completions then
        state.command_completion_index = 1
      end
      state.dirty = true
      return
    end
    if (event.key == "tab" or event.key == "right") and state.cursor == #state.input then
      if accept_command_completion(state) then
        return
      end
    end
    if event.key == "tab" then
      return
    end
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
    local now = now_ms()
    if state.busy_next_frame_at == nil or now >= state.busy_next_frame_at then
      state.busy_tick = (state.busy_tick or 0) + 1
      state.busy_phase = ((state.busy_phase or 0) % 3) + 1
      state.busy_next_frame_at = now + TUI_CONST.busy_animation_interval_ms
      state.dirty = true
    end
  end
  if state.dirty or (state.ui and state.ui.dirty) then
    redraw(state)
  end
end

local function clip_text(text, width)
  width = tonumber(width) or 0
  if width <= 0 then
    return ""
  end
  text = tostring(text or ""):gsub("%s+", " ")
  if #text <= width then
    return text
  end
  if width <= 3 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 3) .. "..."
end

local function pad_right(text, width)
  text = clip_text(text, width)
  return text .. string.rep(" ", math.max(0, width - #text))
end

local function resume_preview_line(info, row, width)
  if type(info) ~= "table" then
    return ""
  end
  if row == 0 then
    return ansi.bold("Preview")
  elseif row == 1 then
    return ansi.dim(clip_text(session.describe_session(info), width))
  elseif row == 2 then
    return ""
  end
  local line = (info.preview or {})[row - 2]
  if line then
    return clip_text(line, width)
  end
  return ""
end

local function draw_resume_picker(infos, selected, offset, scope)
  local width, height = current_size()
  local list_start = 3
  local list_rows = math.max(1, height - 4)
  local split = width >= 70
  local left_width = split and math.max(32, math.floor(width * 0.45)) or width
  local right_width = split and math.max(1, width - left_width - 3) or 0
  local selected_info = infos[selected]

  local scope_label
  if scope == "all" then
    scope_label = ansi.dim("○ Current Folder | ") .. ansi.bold(ansi.cyan("◉ All"))
  else
    scope_label = ansi.bold(ansi.cyan("◉ Current Folder")) .. ansi.dim(" | ○ All")
  end

  psi.tui_clear()
  psi.tui_draw_line(1, ansi.bold(ansi.cyan("Resume session")) .. "  " .. scope_label)
  psi.tui_draw_line(
    2,
    ansi.dim("Enter selects  Esc cancels  Up/Down or Ctrl-P/Ctrl-N moves  Tab toggles scope")
  )
  if #infos == 0 then
    local hint
    if scope == "all" then
      hint = "  No sessions found."
    else
      hint = "  No sessions in current folder. Press Tab to view all."
    end
    psi.tui_draw_line(list_start, ansi.dim(hint))
    psi.tui_set_cursor(math.min(height, list_start), 1, false)
    psi.tui_refresh()
    return
  end
  for row = 0, list_rows - 1 do
    local info = infos[offset + row]
    local text = ""
    if info then
      local marker = (offset + row == selected) and "> " or "  "
      text = pad_right(marker .. session.describe_session(info), left_width)
      if offset + row == selected then
        text = ansi.bold(ansi.cyan(text))
      end
    end
    if split then
      text = text .. ansi.dim("│ ") .. resume_preview_line(selected_info, row, right_width)
    end
    psi.tui_draw_line(list_start + row, text)
  end
  psi.tui_set_cursor(math.min(height, list_start + selected - offset), 1, false)
  psi.tui_refresh()
end

-- Open the resume picker. `current_infos` is the cwd-scoped list (may
-- be empty). The picker fetches the "all" list lazily on first Tab
-- toggle. Returns the absolute file path to load, or nil on cancel.
choose_session_tui = function(current_infos)
  local scopes = {
    current = current_infos or {},
    all = nil, -- lazy
  }
  local scope = "current"
  local selected = #scopes.current > 0 and 1 or 0
  local offset = 1
  while true do
    local infos = scopes[scope] or {}
    local _, height = current_size()
    local list_rows = math.max(1, height - 4)
    if #infos == 0 then
      selected = 0
      offset = 1
    else
      if selected < 1 then
        selected = 1
      elseif selected > #infos then
        selected = #infos
      end
      if selected < offset then
        offset = selected
      elseif selected >= offset + list_rows then
        offset = selected - list_rows + 1
      end
    end
    draw_resume_picker(infos, selected, offset, scope)

    local event = psi.tui_poll_key(-1)
    local key = event and event.key or nil
    if key == "enter" then
      if infos[selected] then
        return infos[selected].path
      end
    elseif key == "escape" or key == "ctrl-d" then
      return nil
    elseif key == "tab" then
      if scope == "current" then
        if scopes.all == nil then
          scopes.all = session.list_all_sessions() or {}
        end
        scope = "all"
      else
        scope = "current"
      end
      selected = #(scopes[scope] or {}) > 0 and 1 or 0
      offset = 1
    elseif (key == "up" or key == "ctrl-p") and selected > 1 then
      selected = selected - 1
    elseif (key == "down" or key == "ctrl-n") and selected < #infos then
      selected = selected + 1
    elseif key == "page-up" then
      selected = math.max(1, selected - list_rows)
    elseif key == "page-down" then
      selected = math.min(#infos, selected + list_rows)
    end
  end
end

-- Mirror modes.lua: a --session value with no path separator and no
-- .jsonl suffix is treated as a session id (or unique prefix) and
-- resolved against the on-disk session store. Required so the
-- `Resume with: psi --session <id>` line printed at TUI exit
-- round-trips back through this entrypoint.
local function looks_like_session_id(value)
  if type(value) ~= "string" or value == "" then
    return false
  end
  if value:find("/", 1, true) or value:find("\\", 1, true) then
    return false
  end
  if value:sub(-6) == ".jsonl" then
    return false
  end
  return true
end

local function bootstrap_session(opts)
  if opts.session_file and opts.session_file ~= "" then
    if looks_like_session_id(opts.session_file) then
      local resolved, find_err = session.find_session_by_id(opts.session_file, psi.cwd())
      if not resolved then
        return false, find_err
      end
      opts.session_file = resolved
    end
    local ok, err = session.load(opts.session_file)
    if not ok then
      return false, err
    end
    return true
  end

  if opts.continue_recent then
    local most_recent = session.most_recent_session(psi.cwd())
    if most_recent then
      opts.session_file = most_recent
      local ok, load_err = session.load(most_recent)
      if not ok then
        return false, load_err
      end
      return true
    end
    -- Fall through to creating a fresh session in this cwd, matching
    -- pi-mono's --continue semantics.
  end

  if opts.resume then
    -- Open the picker unconditionally (even with zero sessions in
    -- this cwd) so the user can Tab to the "all sessions" scope.
    local infos = session.list_sessions(psi.cwd())
    local selected = choose_session_tui(infos)
    if not selected then
      return false, "no session selected"
    end
    opts.session_file = selected
    local ok, load_err = session.load(selected)
    if not ok then
      return false, load_err
    end
    return true
  end

  local path = session.ensure_default_path()
  if not path then
    return false, "could not determine default session path"
  end
  session.announce_start()
  return true
end

function M.run(opts)
  agent.configure(opts)

  local layout_mode = chat.resolve_mode(opts)
  local alt_screen_active = layout_mode == chat.CHAT
    or not not opts.resume
    or not not opts.continue_recent

  -- The resume picker and chat bootstrap use absolute positioning; keep that
  -- contained in alt-screen without making inline TUI the default.
  if alt_screen_active then
    chat.set_alt_screen(true)
  end

  local ok, err = bootstrap_session(opts)
  if not ok then
    if alt_screen_active then
      chat.set_alt_screen(false)
    end
    io.stderr:write("failed to load session file: " .. tostring(err) .. "\n")
    return false
  end

  if alt_screen_active then
    chat.set_alt_screen(false)
    alt_screen_active = false
  end

  local state = new_state(opts)
  state.layout_mode = layout_mode
  rebuild_from_session(state)

  -- Direct provider writes corrupt the alt-screen paint; this subscriber
  -- also disables psi.notice's io.stderr fallback while the TUI runs.
  if psi.events and psi.events.on then
    psi.events.on("notice", function(payload)
      if type(payload) ~= "table" then
        return
      end
      local text = tostring(payload.text or "")
      if text == "" then
        return
      end
      local is_error = payload.level == "error" or payload.level == "warn"
      add_entry(state, is_error and "error" or "info", text)
      if state.running then
        redraw(state)
      end
    end)
  end

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
      if state.dirty or (state.ui and state.ui.dirty) then
        redraw(state)
      end
    end
  end, debug.traceback)

  psi.tui_set_tick_handler(nil)
  psi.tui_set_tool_progress_handler(nil)
  session.announce_shutdown()

  if state.layout_mode == chat.CHAT then
    -- Drop cursor onto a fresh line below the input box so the shell
    -- prompt comes back without overwriting our last paint.
    if type(psi.tui_write) == "function" then
      psi.tui_write("\27[0m\27[?25h\n")
    end
  elseif alt_screen_active then
    chat.set_alt_screen(false)
  end

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

function M._debug_nonstreamed_assistant_reply(reply, assistant_streamed)
  local state = {
    entries = {},
    dirty = false,
    entries_version = 0,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    flat_cache_width = nil,
    flat_cache_version = nil,
    flat_cache_lines = nil,
  }
  local added = add_nonstreamed_assistant_reply(state, reply, assistant_streamed)
  local entry = state.entries[1] or {}
  return table.concat({
    tostring(added),
    tostring(#state.entries),
    tostring(entry.kind or ""),
    tostring(entry.text or ""),
  }, "|")
end

function M._debug_streaming_assistant_rendered(deltas)
  local state = {
    width = 80,
    entries = {},
    dirty = false,
    entries_version = 0,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    flat_cache_width = nil,
    flat_cache_version = nil,
    flat_cache_lines = nil,
    streaming_assistant_index = nil,
    streaming_thinking_index = nil,
    scroll_offset = 0,
  }
  for _, delta in ipairs(type(deltas) == "table" and deltas or { deltas }) do
    observer_text_delta(state, delta)
  end
  local out = {}
  for _, line in ipairs(flattened_render_lines(state)) do
    out[#out + 1] = strip_ansi(line.text or "")
  end
  return table.concat(out, "\n")
end

function M._debug_tool_call_text_after_assistant()
  render.handle_event("before-turn", {})
  render.handle_event("assistant-text", { text = "assistant text" })
  return tool_call_text("toolu_debug", "read", { path = "README.md" })
end

function M._debug_completed_write_tool_block()
  local state = {
    width = 80,
    entries = {},
    dirty = false,
    entries_version = 0,
    flat_cache_width = nil,
    flat_cache_version = nil,
    flat_cache_lines = nil,
    total_cache_width = nil,
    total_cache_version = nil,
    total_cache_lines = nil,
    scroll_offset = 0,
    streaming_assistant_index = nil,
    streaming_thinking_index = nil,
  }
  observer_tool_call(
    state,
    "toolu_write",
    "write",
    psi.json_encode({ path = "notes.txt", content = "alpha\nbeta" })
  )
  observer_tool_result(
    state,
    "toolu_write",
    "write",
    psi.json_encode({ ok = true, path = "notes.txt", bytes_written = 10 })
  )
  local out = {}
  for _, line in ipairs(flattened_render_lines(state)) do
    out[#out + 1] = line.text or ""
  end
  return table.concat(out, "\n")
end

function M._debug_persisted_tool_result_text(tool_name, content_text, is_error)
  local message = {
    toolCallId = "toolu_debug",
    toolName = tool_name,
    isError = is_error,
  }
  local payload = persisted_tool_result_payload(message, content_text or "")
  local rendered = tool_result_text(message.toolCallId, message.toolName, payload)
  return rendered or ""
end

function M._debug_busy_animation_frames(times)
  local names = {
    "time_ms",
    "tui_poll_key",
    "tui_size",
    "tui_render_frame",
    "tui_render_lines",
    "stdout_write",
    "tui_clear",
    "cwd",
    "session_id",
    "session_message_count",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = psi[name]
  end

  local fake_now = 0
  psi.time_ms = function()
    return fake_now
  end
  psi.tui_poll_key = function()
    return nil
  end
  psi.tui_size = function()
    return { width = 80, height = 24 }
  end
  psi.tui_render_frame = function() end
  psi.tui_render_lines = function() end
  psi.stdout_write = function() end
  psi.tui_clear = function() end
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
      input = "",
      cursor = 0,
      editor_mode = "insert",
      selection_anchor = nil,
      selection_kind = nil,
      clipboard = "",
      pending_key = nil,
      block_edit = nil,
      force_physical_clear = false,
      busy = true,
      busy_label = "thinking",
      busy_phase = 0,
      busy_tick = 0,
      busy_next_frame_at = 600,
      busy_started_at = os.time(),
      running = true,
      scroll_offset = 0,
      status_text = nil,
      status_is_error = false,
      show_thinking = false,
      show_hardware_cursor = false,
      width = 80,
      height = 24,
      renderer = tui_renderer.new({ line_primitive = true }),
      input_layout = default_input_layout(24),
      tui_caps = { raw_ansi = false },
      streaming_assistant_index = nil,
      streaming_thinking_index = nil,
      entries_version = 0,
      total_cache_width = nil,
      total_cache_version = nil,
      total_cache_lines = nil,
      dirty = false,
    }
    local out = {}
    for _, value in ipairs(times or {}) do
      fake_now = value
      tick(state)
      out[#out + 1] = tostring(state.busy_tick) .. ":" .. tostring(state.busy_phase)
    end
    return table.concat(out, "|")
  end, debug.traceback)

  for _, name in ipairs(names) do
    psi[name] = saved[name]
  end
  if not ok then
    error(result)
  end
  return result
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

function M._debug_pending_queue_lines(width, max_rows)
  return pending_queue_lines(width, max_rows)
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
    prompt_history = {},
    history_index = nil,
    history_draft = "",
    history_search_active = false,
    history_search_query = "",
    history_search_draft = "",
    history_search_index = nil,
    status_text = debug_options.status_text,
    status_is_error = not not debug_options.status_is_error,
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
    running = state.running,
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

function M._debug_history_sequence(history, keys, input)
  local state = {
    prompt_history = history or {},
    history_index = nil,
    history_draft = "",
    history_search_active = false,
    history_search_query = "",
    history_search_draft = "",
    history_search_index = nil,
    input = input or "",
    cursor = #(input or ""),
    busy = false,
    editor_mode = "insert",
    selection_anchor = nil,
    pending_key = nil,
    scroll_offset = 0,
    height = 24,
    status_text = nil,
    status_is_error = false,
    dirty = false,
  }
  for _, key in ipairs(keys or {}) do
    if key == "up" then
      history_up(state)
    elseif key == "down" then
      history_down(state)
    elseif key == "line-up" then
      if not (history_up_applicable(state) and history_up(state)) then
        state.scrolled = true
      end
    elseif key == "line-down" then
      if not (history_down_applicable(state) and history_down(state)) then
        state.scrolled = true
      end
    elseif key == "ctrl-r" or key == "reverse" then
      history_reverse_search(state, true)
    elseif key == "backspace" then
      if state.history_search_active then
        history_search_backspace(state)
      else
        delete_backward(state)
      end
    elseif key == "enter" then
      if state.history_search_active then
        history_search_accept(state)
      end
    elseif key == "type" then
      if state.history_search_active then
        history_search_append(state, "x")
      else
        insert_text(state, "x")
      end
    elseif type(key) == "string" and key:sub(1, 5) == "text:" then
      local text = key:sub(6)
      if state.history_search_active then
        history_search_append(state, text)
      else
        insert_text(state, text)
      end
    end
  end
  return {
    input = state.input,
    cursor = state.cursor,
    history_index = state.history_index,
    history_search_active = state.history_search_active,
    history_search_query = state.history_search_query,
    status_text = state.status_text,
    scrolled = state.scrolled,
  }
end

function M._debug_redraw_counts(input, debug_options)
  debug_options = type(debug_options) == "table" and debug_options or {}
  local names = {
    "tui_size",
    "tui_clear",
    "tui_draw_line",
    "tui_draw_raw_line",
    "tui_render_frame",
    "tui_render_lines",
    "tui_set_cursor",
    "tui_refresh",
    "stdout_write",
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
    line_frames = {},
    writes = {},
    clears = 0,
    cursor_sets = 0,
    refreshes = 0,
  }
  local function reset_calls()
    calls.draw_rows = {}
    calls.raw_rows = {}
    calls.frames = {}
    calls.line_frames = {}
    calls.writes = {}
    calls.clears = 0
    calls.cursor_sets = 0
    calls.refreshes = 0
  end
  local debug_width = math.max(1, tonumber(debug_options.width) or 80)
  local debug_height = math.max(1, tonumber(debug_options.height) or 24)
  psi.tui_size = function()
    return { width = debug_width, height = debug_height }
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
  local previous_line_frame = nil
  local previous_line_top = nil
  local function line_frame_output(lines, force_full, top)
    local out = {}
    lines = type(lines) == "table" and lines or {}
    top = math.max(1, tonumber(top) or 1)
    if
      force_full
      or previous_line_frame == nil
      or #previous_line_frame ~= #lines
      or previous_line_top ~= top
    then
      for row, line in ipairs(lines) do
        out[#out + 1] = "\27[" .. tostring(top + row - 1) .. ";1H\27[2K" .. tostring(line or "")
      end
    else
      for row, line in ipairs(lines) do
        if tostring(previous_line_frame[row] or "") ~= tostring(line or "") then
          out[#out + 1] = "\27[" .. tostring(top + row - 1) .. ";1H\27[2K" .. tostring(line or "")
        end
      end
    end
    previous_line_frame = {}
    previous_line_top = top
    for row, line in ipairs(lines) do
      previous_line_frame[row] = tostring(line or "")
    end
    return table.concat(out)
  end
  psi.tui_render_lines = function(lines, row, col, visible, force_full, top)
    local output = line_frame_output(lines, force_full, top)
    calls.line_frames[#calls.line_frames + 1] = {
      lines = lines,
      output = output,
      row = row,
      col = col,
      visible = visible,
      force_full = force_full,
      top = top,
    }
    if force_full then
      calls.frames[#calls.frames + 1] = {
        frame = output,
        row = row,
        col = col,
        visible = visible,
        top = top,
      }
    elseif output ~= "" then
      calls.writes[#calls.writes + 1] = output
    end
  end
  psi.stdout_write = function(text)
    calls.writes[#calls.writes + 1] = text or ""
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
      busy_label = "working",
      busy_phase = 1,
      busy_tick = 0,
      busy_next_frame_at = nil,
      busy_started_at = os.time(),
      running = true,
      scroll_offset = 0,
      status_text = nil,
      status_is_error = false,
      show_thinking = false,
      show_hardware_cursor = not not debug_options.show_hardware_cursor,
      width = debug_width,
      height = inline_viewport_height(debug_height),
      terminal_height = debug_height,
      renderer = tui_renderer.new({ line_primitive = true }),
      input_layout = default_input_layout(inline_viewport_height(debug_height)),
      tui_caps = { raw_ansi = false },
      streaming_assistant_index = nil,
      streaming_thinking_index = nil,
      entries_version = 0,
      total_cache_width = nil,
      total_cache_version = nil,
      total_cache_lines = nil,
      prompt_history = {},
      history_index = nil,
      history_draft = "",
      dirty = true,
    }
    refresh_input_layout(state)
    redraw(state)
    local rows = layout_rows(state)
    local first_frames = #calls.frames
    local first_frame = calls.frames[1] and calls.frames[1].frame or ""
    local first_line_width = 0
    if calls.line_frames[1] and calls.line_frames[1].lines then
      first_line_width = tui_text.visible_width(calls.line_frames[1].lines[1] or "")
    end
    local first_visible = calls.frames[1] and calls.frames[1].visible or false
    local first_col = calls.frames[1] and calls.frames[1].col or nil
    reset_calls()
    state.busy_tick = 1
    state.dirty = true
    redraw(state)
    local second_frames = #calls.frames
    local second_frame = calls.frames[1] and calls.frames[1].frame or ""
    local second_write = calls.writes[1] or ""
    local second_output = second_frame ~= "" and second_frame or second_write
    local second_top = calls.line_frames[1] and tonumber(calls.line_frames[1].top) or 1
    local second_input_draws = 0
    for row = rows.input_start_row, rows.input_start_row + rows.input_rows + 1 do
      local physical_row = second_top + row - 1
      if second_output:find("\27%[" .. tostring(physical_row) .. ";1H", 1, false) ~= nil then
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
    local stale_write = calls.writes[1] or ""
    local stale_output = stale_frame ~= "" and stale_frame or stale_write
    local stale_top = calls.line_frames[1] and tonumber(calls.line_frames[1].top) or 1
    local line_clears = stale_output:find("\27%[2K", 1, false) ~= nil and 1 or 0
    for row = rows.transcript_start, rows.input_start_row - 1 do
      local physical_row = stale_top + row - 1
      stale_clears = stale_clears
        + (
          stale_output:find("\27%[" .. tostring(physical_row) .. ";1H", 1, false) ~= nil and 1
          or 0
        )
    end
    return {
      first_frames = first_frames,
      first_frame = first_frame,
      first_line_width = first_line_width,
      first_visible = first_visible,
      first_col = first_col,
      second_frames = second_frames,
      second_writes = #calls.writes,
      second_input_draws = second_input_draws,
      second_clears = calls.clears,
      stale_clears = stale_clears,
      line_clears = line_clears,
      raw_draws = #calls.raw_rows,
      draw_rows = #calls.draw_rows,
      cursor_sets = calls.cursor_sets,
      refreshes = calls.refreshes,
      second_frame = second_frame,
      second_write = second_write,
      second_output = second_output,
      stale_frame = stale_frame,
      stale_write = stale_write,
      stale_output = stale_output,
      renderer_full = state.renderer and state.renderer.full_redraws or 0,
      renderer_diff = state.renderer and state.renderer.diff_redraws or 0,
      renderer_last_mode = state.renderer and state.renderer.last_mode or "",
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

-- Drive chat-mode redraw through a sequence of entry mutations and capture
-- the bytes psi.tui_write would emit on each step, so smoke tests can verify
-- that committed transcript lines are written to scrollback exactly once
-- while the live region is repainted in place.
function M._debug_chat_redraw_sequence(steps)
  steps = steps or {}
  local saved_size = psi.tui_size
  local saved_write = psi.tui_write
  local saved_set_alt = psi.tui_set_alt_screen_active
  local writes = {}
  psi.tui_size = function()
    return { width = 80, height = 24 }
  end
  psi.tui_write = function(text)
    writes[#writes + 1] = text or ""
  end
  psi.tui_set_alt_screen_active = function() end

  local ok, result = xpcall(function()
    local state = new_state({ model = "debug", layout_mode = chat.CHAT })
    state.layout_mode = chat.CHAT
    local snapshots = {}
    for _, step in ipairs(steps) do
      if step.kind == "user" then
        add_entry(state, "user", step.text or "")
      elseif step.kind == "assistant" then
        add_entry(state, "assistant", step.text or "")
      elseif step.kind == "set_input" then
        state.input = step.text or ""
        state.cursor = #state.input
        state.dirty = true
      elseif step.kind == "rebuild" then
        rebuild_from_session(state, step.entries or {})
      end
      writes = {}
      chat.redraw(state)
      snapshots[#snapshots + 1] = {
        write_count = #writes,
        output = table.concat(writes),
        committed_entries = state.chat_committed_entry_count,
        live_rows = state.chat_live_rows,
        cursor_offset = state.chat_cursor_offset,
        entries = #state.entries,
      }
    end
    return snapshots
  end, debug.traceback)

  psi.tui_size = saved_size
  psi.tui_write = saved_write
  psi.tui_set_alt_screen_active = saved_set_alt
  if not ok then
    error(result)
  end
  return result
end

return M
