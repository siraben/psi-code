-- Shared terminal text helpers for Lua-owned TUI rendering.
--
-- This module is intentionally dependency-free. It is not a complete
-- Unicode line-breaking implementation, but it handles the cases that make a
-- terminal renderer visibly wrong: ANSI/OSC escapes, host-provided cell
-- widths, zero-width-joiner emoji clusters, and regional indicator flags.

local M = {}
local host = type(psi) == "table" and psi or {}
local host_strip_ansi = type(host.tui_text_strip_ansi) == "function" and host.tui_text_strip_ansi
  or nil
local host_visible_width = type(host.tui_text_visible_width) == "function"
    and host.tui_text_visible_width
  or nil
local host_byte_index_for_width = type(host.tui_text_byte_index_for_width) == "function"
    and host.tui_text_byte_index_for_width
  or nil
local host_pad_line = type(host.tui_text_pad_line) == "function" and host.tui_text_pad_line or nil
local host_wrap_ansi = type(host.tui_text_wrap_ansi) == "function" and host.tui_text_wrap_ansi
  or nil
local host_cell_width = type(host.cell_width) == "function" and host.cell_width or nil

local EMPTY = ""
local ESC = string.char(27)
local BEL = string.char(7)
local ANSI_RESET_STYLE = ESC .. "[0m"
local ANSI_UNDERLINE_OFF = ESC .. "[24m"
local OSC8_CLOSE_PREFIX = ESC .. "]8;;"
local BYTE_SPACE = 32
local BYTE_TAB = 9
local BYTE_NEWLINE = 10
local BYTE_CR = 13
local BYTE_ESC = 27

local function read_escape(text, i)
  if text:byte(i) ~= BYTE_ESC then
    return nil
  end
  local n = #text
  local next_byte = text:byte(i + 1)
  if next_byte == nil then
    return text:sub(i, i), i + 1
  end
  if next_byte == string.byte("[") then
    local j = i + 2
    while j <= n do
      local byte = text:byte(j)
      if byte >= 0x40 and byte <= 0x7e then
        return text:sub(i, j), j + 1
      end
      j = j + 1
    end
    return text:sub(i), n + 1
  end
  if next_byte == string.byte("]") or next_byte == string.byte("_") then
    local j = i + 2
    while j <= n do
      local byte = text:byte(j)
      if byte == string.byte(BEL) then
        return text:sub(i, j), j + 1
      end
      if byte == BYTE_ESC and text:sub(j + 1, j + 1) == "\\" then
        return text:sub(i, j + 1), j + 2
      end
      j = j + 1
    end
    return text:sub(i), n + 1
  end
  if next_byte == string.byte("=") or next_byte == string.byte(">") then
    return text:sub(i, i + 1), i + 2
  end
  return text:sub(i, i + 1), i + 2
end

local function strip_ansi(text)
  text = tostring(text or EMPTY)
  local out = {}
  local i = 1
  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      i = next_i
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.strip_ansi(text)
  if host_strip_ansi then
    return host_strip_ansi(text)
  end
  return strip_ansi(text)
end

local function decode_utf8(text, i)
  local b1 = text:byte(i)
  if b1 == nil then
    return nil, i, EMPTY
  end
  if b1 < 0x80 then
    return b1, i + 1, text:sub(i, i)
  end
  local b2 = text:byte(i + 1)
  local b3 = text:byte(i + 2)
  local b4 = text:byte(i + 3)
  if b1 >= 0xc2 and b1 <= 0xdf and b2 ~= nil and b2 >= 0x80 and b2 <= 0xbf then
    return ((b1 - 0xc0) * 0x40) + (b2 - 0x80), i + 2, text:sub(i, i + 1)
  end
  if
    b1 >= 0xe0
    and b1 <= 0xef
    and b2 ~= nil
    and b3 ~= nil
    and b2 >= 0x80
    and b2 <= 0xbf
    and b3 >= 0x80
    and b3 <= 0xbf
  then
    return ((b1 - 0xe0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80), i + 3, text:sub(i, i + 2)
  end
  if
    b1 >= 0xf0
    and b1 <= 0xf4
    and b2 ~= nil
    and b3 ~= nil
    and b4 ~= nil
    and b2 >= 0x80
    and b2 <= 0xbf
    and b3 >= 0x80
    and b3 <= 0xbf
    and b4 >= 0x80
    and b4 <= 0xbf
  then
    return ((b1 - 0xf0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80),
      i + 4,
      text:sub(i, i + 3)
  end
  return b1, i + 1, text:sub(i, i)
end

local function in_range(cp, first, last)
  return cp >= first and cp <= last
end

local function is_combining(cp)
  return in_range(cp, 0x0300, 0x036f)
    or in_range(cp, 0x1ab0, 0x1aff)
    or in_range(cp, 0x1dc0, 0x1dff)
    or in_range(cp, 0x20d0, 0x20ff)
    or in_range(cp, 0xfe20, 0xfe2f)
end

local function is_variation_selector(cp)
  return in_range(cp, 0xfe00, 0xfe0f) or in_range(cp, 0xe0100, 0xe01ef)
end

local function is_regional_indicator(cp)
  return in_range(cp, 0x1f1e6, 0x1f1ff)
end

local function is_wide(cp)
  return in_range(cp, 0x1100, 0x115f)
    or in_range(cp, 0x2329, 0x232a)
    or in_range(cp, 0x2e80, 0xa4cf)
    or in_range(cp, 0xac00, 0xd7a3)
    or in_range(cp, 0xf900, 0xfaff)
    or in_range(cp, 0xfe10, 0xfe19)
    or in_range(cp, 0xfe30, 0xfe6f)
    or in_range(cp, 0xff00, 0xff60)
    or in_range(cp, 0xffe0, 0xffe6)
    or in_range(cp, 0x1f000, 0x1faff)
    or in_range(cp, 0x20000, 0x3fffd)
end

local function is_control(cp)
  return cp == BYTE_NEWLINE or cp == BYTE_CR or cp < 0x20 or in_range(cp, 0x7f, 0x9f)
end

local function codepoint_width(cp)
  if cp == nil then
    return 0
  end
  if cp == BYTE_TAB then
    return 3
  end
  if host_cell_width then
    return host_cell_width(cp)
  end
  if is_control(cp) then
    return 0
  end
  if cp == 0x200d or is_combining(cp) or is_variation_selector(cp) then
    return 0
  end
  if is_wide(cp) then
    return 2
  end
  return 1
end

local function is_zero_width_cluster_modifier(cp)
  return cp ~= 0x200d and not is_control(cp) and codepoint_width(cp) == 0
end

local function next_cluster(text, i)
  local start = i
  local cp, next_i = decode_utf8(text, i)
  local width = codepoint_width(cp)
  local saw_zwj = false

  if is_regional_indicator(cp) then
    local cp2, next2 = decode_utf8(text, next_i)
    if is_regional_indicator(cp2) then
      return text:sub(start, next2 - 1), 2, next2, cp
    end
  end

  i = next_i
  while i <= #text do
    local next_cp, after = decode_utf8(text, i)
    if next_cp == nil then
      break
    end
    if is_zero_width_cluster_modifier(next_cp) then
      i = after
    elseif next_cp == 0x200d then
      saw_zwj = true
      i = after
    elseif saw_zwj then
      width = math.max(width, codepoint_width(next_cp), 2)
      saw_zwj = false
      i = after
    else
      break
    end
  end
  return text:sub(start, i - 1), width, i, cp
end

function M.visible_width(text)
  if host_visible_width then
    return host_visible_width(text)
  end
  local width = 0
  text = tostring(text or EMPTY)
  local i = 1
  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      i = next_i
    else
      local _, cluster_width, after = next_cluster(text, i)
      width = width + cluster_width
      i = after
    end
  end
  return width
end

function M.pad_line(text, width)
  if host_pad_line then
    return host_pad_line(text, width)
  end
  text = tostring(text or EMPTY)
  width = math.max(1, tonumber(width) or 1)
  return text .. string.rep(" ", math.max(0, width - M.visible_width(text)))
end

function M.byte_index_for_width(text, width)
  if host_byte_index_for_width then
    return host_byte_index_for_width(text, width)
  end
  text = tostring(text or EMPTY)
  width = math.max(0, tonumber(width) or 0)
  if width <= 0 then
    return 0
  end
  local seen = 0
  local i = 1
  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      i = next_i
    else
      local _, cluster_width, after = next_cluster(text, i)
      if seen + cluster_width > width then
        return i - 1
      end
      seen = seen + cluster_width
      i = after
    end
  end
  return #text
end

local update_active_from_text

function M.clip_ansi(text, width)
  text = tostring(text or EMPTY)
  width = math.max(0, tonumber(width) or 0)
  if M.visible_width(text) <= width then
    return text
  end
  local byte_index = M.byte_index_for_width(text, width)
  local clipped = text:sub(1, byte_index)
  local active = {}
  update_active_from_text(active, clipped)
  if active.hyperlink ~= nil then
    clipped = clipped .. OSC8_CLOSE_PREFIX .. (active.hyperlink_terminator or BEL)
  elseif #active > 0 then
    clipped = clipped .. ANSI_RESET_STYLE
  end
  return clipped
end

local function is_space_cluster(cluster)
  local byte = cluster ~= nil and cluster:byte(1) or nil
  return byte == BYTE_SPACE or byte == BYTE_TAB
end

local function ansi_active_prefix(active)
  local out = {}
  for _, seq in ipairs(active) do
    out[#out + 1] = seq
  end
  if active.hyperlink ~= nil then
    out[#out + 1] = active.hyperlink
  end
  return table.concat(out)
end

local function line_end_reset(active)
  local out = {}
  if active.underline then
    out[#out + 1] = ANSI_UNDERLINE_OFF
  end
  if active.hyperlink ~= nil then
    out[#out + 1] = OSC8_CLOSE_PREFIX .. (active.hyperlink_terminator or BEL)
  end
  return table.concat(out)
end

local function update_active_sgr(active, seq)
  local body = seq:match("^\27%[([%d;]*)m$")
  if body == nil then
    return
  end
  if body == "" or body == "0" or body:match("^0;") or body:match(";0;") or body:match(";0$") then
    for i = #active, 1, -1 do
      active[i] = nil
    end
    active.underline = false
    return
  end
  local values = {}
  for code in body:gmatch("%d+") do
    values[#values + 1] = tonumber(code)
  end
  local i = 1
  while i <= #values do
    local value = values[i]
    if value == 0 then
      active.underline = false
    elseif value == 4 then
      active.underline = true
    elseif value == 24 then
      active.underline = false
    elseif value == 38 or value == 48 then
      local mode = values[i + 1]
      if mode == 5 then
        i = i + 2
      elseif mode == 2 then
        i = i + 4
      end
    end
    i = i + 1
  end
  active[#active + 1] = seq
end

local function update_active_osc8(active, seq)
  if not seq:match("^\27%]8;") then
    return
  end
  local terminator
  local payload
  if seq:sub(-1) == BEL then
    terminator = BEL
    payload = seq:sub(1, -2)
  elseif seq:sub(-2) == ESC .. "\\" then
    terminator = ESC .. "\\"
    payload = seq:sub(1, -3)
  else
    return
  end
  local target = payload:match("^\27%]8;[^;]*;(.*)$")
  if target == nil then
    return
  end
  if target == "" then
    active.hyperlink = nil
    active.hyperlink_terminator = nil
  else
    active.hyperlink = seq
    active.hyperlink_terminator = terminator
  end
end

local function update_active_escape(active, seq)
  update_active_sgr(active, seq)
  update_active_osc8(active, seq)
end

update_active_from_text = function(active, text)
  local i = 1
  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      update_active_escape(active, seq)
      i = next_i
    else
      i = i + 1
    end
  end
end

local function append_active_prefix(out, active)
  if #out == 0 and #active > 0 then
    out[#out + 1] = ansi_active_prefix(active)
  end
end

function M.slice_by_columns(text, start_col, width, strict)
  text = tostring(text or EMPTY)
  start_col = math.max(0, tonumber(start_col) or 0)
  width = math.max(0, tonumber(width) or 0)
  if width <= 0 then
    return ""
  end
  local finish_col = start_col + width
  local active = {}
  local out = {}
  local col = 0
  local i = 1

  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      update_active_sgr(active, seq)
      if col >= start_col and col < finish_col then
        out[#out + 1] = seq
      end
      i = next_i
    else
      local cluster, cluster_width, after = next_cluster(text, i)
      local cluster_end = col + cluster_width
      local include = cluster_width == 0 and col >= start_col and col < finish_col
      if cluster_width > 0 then
        if strict then
          include = col >= start_col and cluster_end <= finish_col
        else
          include = cluster_end > start_col and col < finish_col
        end
      end
      if include then
        append_active_prefix(out, active)
        out[#out + 1] = cluster
      end
      col = cluster_end
      if col >= finish_col and cluster_width > 0 then
        break
      end
      i = after
    end
  end

  local rendered = table.concat(out)
  if rendered ~= "" and #active > 0 then
    rendered = rendered .. ESC .. "[0m"
  end
  return rendered
end

function M.truncate_columns(text, width, strict)
  return M.slice_by_columns(text, 0, width, strict ~= false)
end

function M.wrap_ansi(text, width, opts)
  opts = type(opts) == "table" and opts or {}
  if host_wrap_ansi then
    return host_wrap_ansi(text, width, opts)
  end
  text = tostring(text or EMPTY)
  width = math.max(1, tonumber(width) or 1)
  local lines = {}
  local active = {}
  local line = {}
  local line_width = 0
  local word = {}
  local word_width = 0
  local pending_space = nil
  local pending_space_width = 0
  local soft_wrapped = false

  local function emit_line()
    local rendered = table.concat(line)
    local reset = line_end_reset(active)
    if rendered ~= "" and reset ~= "" then
      rendered = rendered .. reset
    end
    lines[#lines + 1] = rendered
    line = {}
    line_width = 0
    local prefix = ansi_active_prefix(active)
    if prefix ~= "" then
      line[#line + 1] = prefix
    end
  end

  local function append_piece(piece, piece_width)
    if piece_width == 0 then
      line[#line + 1] = piece
      return
    end
    if line_width > 0 and line_width + piece_width > width then
      emit_line()
      soft_wrapped = true
    end
    line[#line + 1] = piece
    line_width = line_width + piece_width
    soft_wrapped = false
  end

  if opts.preserve_whitespace then
    local i = 1
    while i <= #text do
      local seq, next_i = read_escape(text, i)
      if seq then
        line[#line + 1] = seq
        update_active_sgr(active, seq)
        i = next_i
      else
        local cluster, cluster_width, after = next_cluster(text, i)
        append_piece(cluster, cluster_width)
        i = after
      end
    end
    if #line > 0 or #lines == 0 then
      lines[#lines + 1] = table.concat(line)
    end
    return lines
  end

  local function flush_word()
    if #word == 0 then
      return
    end
    local word_text = table.concat(word)
    -- Preserve the full whitespace run so indentation is not collapsed, and
    -- keep leading whitespace at the start of a source line. Only suppress
    -- whitespace that would begin a soft-wrapped continuation line. Mirrors
    -- pi's wrapTextWithAnsi and the native psi_vm_text_wrap_flush_word.
    if pending_space ~= nil then
      local space_width = pending_space_width > 0 and pending_space_width or 1
      if line_width == 0 and soft_wrapped then
        -- Suppress leading whitespace on a soft-wrapped line.
      elseif line_width > 0 and line_width + space_width + word_width > width then
        emit_line()
        soft_wrapped = true
      else
        line[#line + 1] = string.rep(" ", space_width)
        line_width = line_width + space_width
      end
    end
    pending_space = nil
    pending_space_width = 0
    if word_width <= width then
      append_piece(word_text, word_width)
      update_active_from_text(active, word_text)
    else
      local j = 1
      while j <= #word_text do
        local seq, next_j = read_escape(word_text, j)
        if seq then
          line[#line + 1] = seq
          update_active_escape(active, seq)
          j = next_j
        else
          local cluster, cluster_width, after = next_cluster(word_text, j)
          append_piece(cluster, cluster_width)
          j = after
        end
      end
    end
    word = {}
    word_width = 0
  end

  local i = 1
  while i <= #text do
    local seq, next_i = read_escape(text, i)
    if seq then
      word[#word + 1] = seq
      i = next_i
    else
      local cluster, cluster_width, after = next_cluster(text, i)
      if cluster == "\n" then
        flush_word()
        emit_line()
        pending_space = nil
        pending_space_width = 0
        soft_wrapped = false
      elseif is_space_cluster(cluster) then
        flush_word()
        pending_space = " "
        pending_space_width = pending_space_width + (cluster_width > 0 and cluster_width or 1)
      else
        word[#word + 1] = cluster
        word_width = word_width + cluster_width
      end
      i = after
    end
  end
  flush_word()
  if #line > 0 or #lines == 0 then
    lines[#lines + 1] = table.concat(line)
  end
  return lines
end

function M.wrap_plain(text, width)
  return M.wrap_ansi(M.strip_ansi(text), width)
end

return M
