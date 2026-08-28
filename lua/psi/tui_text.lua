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
    or in_range(cp, 0x0483, 0x0489)
    or in_range(cp, 0x0591, 0x05bd)
    or cp == 0x05bf
    or in_range(cp, 0x05c1, 0x05c2)
    or in_range(cp, 0x05c4, 0x05c5)
    or cp == 0x05c7
    or in_range(cp, 0x0610, 0x061a)
    or in_range(cp, 0x064b, 0x065e)
    or cp == 0x0670
    or in_range(cp, 0x06d6, 0x06dc)
    or in_range(cp, 0x06df, 0x06e4)
    or in_range(cp, 0x06e7, 0x06e8)
    or in_range(cp, 0x06ea, 0x06ed)
    or cp == 0x0711
    or in_range(cp, 0x0730, 0x074a)
    or in_range(cp, 0x07a6, 0x07b0)
    or in_range(cp, 0x07eb, 0x07f3)
    or cp == 0x07fd
    or in_range(cp, 0x0816, 0x0819)
    or in_range(cp, 0x081b, 0x0823)
    or in_range(cp, 0x0825, 0x0827)
    or in_range(cp, 0x0829, 0x082d)
    or in_range(cp, 0x0859, 0x085b)
    or in_range(cp, 0x0897, 0x089f)
    or in_range(cp, 0x08ca, 0x08e1)
    or in_range(cp, 0x08e3, 0x08ff)
    or in_range(cp, 0x1ab0, 0x1aff)
    or in_range(cp, 0x1dc0, 0x1dff)
    or in_range(cp, 0x20d0, 0x20ff)
    or in_range(cp, 0xfe20, 0xfe2f)
end

local function is_variation_selector(cp)
  return in_range(cp, 0xfe00, 0xfe0f) or in_range(cp, 0xe0100, 0xe01ef)
end

local function is_regional_indicator(cp)
  return cp ~= nil and in_range(cp, 0x1f1e6, 0x1f1ff)
end

local function is_emoji_modifier(cp)
  return cp ~= nil and in_range(cp, 0x1f3fb, 0x1f3ff)
end

-- Unicode 17 Indic_Conjunct_Break data. Keep these predicates in sync with
-- src/lua/vm.c so Lua-owned editor boundaries match the C rendering helpers.
local INDIC_LINKERS = {
  [0x094d] = true,
  [0x09cd] = true,
  [0x0acd] = true,
  [0x0b4d] = true,
  [0x0c4d] = true,
  [0x0d4d] = true,
  [0x1039] = true,
  [0x17d2] = true,
  [0x1a60] = true,
  [0x1b44] = true,
  [0x1bab] = true,
  [0xa9c0] = true,
  [0xaaf6] = true,
  [0x10a3f] = true,
  [0x11133] = true,
  [0x113d0] = true,
  [0x1193e] = true,
  [0x11a47] = true,
  [0x11a99] = true,
  [0x11f42] = true,
}

local INDIC_CONSONANT_RANGES = {
  { 0x0915, 0x0939 },
  { 0x0958, 0x095f },
  { 0x0978, 0x097f },
  { 0x0995, 0x09a8 },
  { 0x09aa, 0x09b0 },
  { 0x09b2, 0x09b2 },
  { 0x09b6, 0x09b9 },
  { 0x09dc, 0x09dd },
  { 0x09df, 0x09df },
  { 0x09f0, 0x09f1 },
  { 0x0a95, 0x0aa8 },
  { 0x0aaa, 0x0ab0 },
  { 0x0ab2, 0x0ab3 },
  { 0x0ab5, 0x0ab9 },
  { 0x0af9, 0x0af9 },
  { 0x0b15, 0x0b28 },
  { 0x0b2a, 0x0b30 },
  { 0x0b32, 0x0b33 },
  { 0x0b35, 0x0b39 },
  { 0x0b5c, 0x0b5d },
  { 0x0b5f, 0x0b5f },
  { 0x0b71, 0x0b71 },
  { 0x0c15, 0x0c28 },
  { 0x0c2a, 0x0c39 },
  { 0x0c58, 0x0c5a },
  { 0x0d15, 0x0d3a },
  { 0x1000, 0x102a },
  { 0x103f, 0x103f },
  { 0x1050, 0x1055 },
  { 0x105a, 0x105d },
  { 0x1061, 0x1061 },
  { 0x1065, 0x1066 },
  { 0x106e, 0x1070 },
  { 0x1075, 0x1081 },
  { 0x108e, 0x108e },
  { 0x1780, 0x17b3 },
  { 0x1a20, 0x1a54 },
  { 0x1b0b, 0x1b0c },
  { 0x1b13, 0x1b33 },
  { 0x1b45, 0x1b4c },
  { 0x1b83, 0x1ba0 },
  { 0x1bae, 0x1baf },
  { 0x1bbb, 0x1bbd },
  { 0xa989, 0xa98b },
  { 0xa98f, 0xa9b2 },
  { 0xa9e0, 0xa9e4 },
  { 0xa9e7, 0xa9ef },
  { 0xa9fa, 0xa9fe },
  { 0xaa60, 0xaa6f },
  { 0xaa71, 0xaa73 },
  { 0xaa7a, 0xaa7a },
  { 0xaa7e, 0xaa7f },
  { 0xaae0, 0xaaea },
  { 0xabc0, 0xabda },
  { 0x10a00, 0x10a00 },
  { 0x10a10, 0x10a13 },
  { 0x10a15, 0x10a17 },
  { 0x10a19, 0x10a35 },
  { 0x11103, 0x11126 },
  { 0x11144, 0x11144 },
  { 0x11147, 0x11147 },
  { 0x11380, 0x11389 },
  { 0x1138b, 0x1138b },
  { 0x1138e, 0x1138e },
  { 0x11390, 0x113b5 },
  { 0x11900, 0x11906 },
  { 0x11909, 0x11909 },
  { 0x1190c, 0x11913 },
  { 0x11915, 0x11916 },
  { 0x11918, 0x1192f },
  { 0x11a00, 0x11a00 },
  { 0x11a0b, 0x11a32 },
  { 0x11a50, 0x11a50 },
  { 0x11a5c, 0x11a83 },
  { 0x11f04, 0x11f10 },
  { 0x11f12, 0x11f33 },
}

local function is_indic_linker(cp)
  return cp ~= nil and INDIC_LINKERS[cp] == true
end

local function is_indic_consonant(cp)
  if cp == nil or cp < 0x0915 or cp > 0x11f33 then
    return false
  end
  for _, range in ipairs(INDIC_CONSONANT_RANGES) do
    if in_range(cp, range[1], range[2]) then
      return true
    end
  end
  return false
end

local function is_wide(cp)
  return in_range(cp, 0x1100, 0x115f)
    or in_range(cp, 0x2329, 0x232a)
    or (in_range(cp, 0x2e80, 0xa4cf) and cp ~= 0x303f)
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
  return cp ~= nil
    and cp ~= 0x200d
    and not is_control(cp)
    and (is_emoji_modifier(cp) or codepoint_width(cp) == 0)
end

local function next_cluster(text, i)
  local start = i
  local cp, next_i = decode_utf8(text, i)
  local width = codepoint_width(cp)
  local cluster_is_indic = is_indic_consonant(cp)
  local indic_chain_valid = cluster_is_indic
  local indic_linker_pending = false
  local saw_zwj = false

  if is_regional_indicator(cp) then
    width = math.max(width, 2)
    local cp2, next2 = decode_utf8(text, next_i)
    if is_regional_indicator(cp2) then
      next_i = next2
    end
  end

  i = next_i
  while i <= #text do
    local next_cp, after = decode_utf8(text, i)
    if next_cp == nil then
      break
    end
    if indic_chain_valid and is_indic_linker(next_cp) then
      indic_linker_pending = true
      i = after
    elseif next_cp == 0x200c then
      indic_chain_valid = false
      indic_linker_pending = false
      saw_zwj = false
      i = after
    elseif is_zero_width_cluster_modifier(next_cp) then
      i = after
    elseif next_cp == 0x200d then
      -- ZWJ extends an Indic linker chain, but cannot start one by itself.
      if not cluster_is_indic then
        saw_zwj = true
      end
      i = after
    elseif indic_chain_valid and indic_linker_pending and is_indic_consonant(next_cp) then
      width = width + codepoint_width(next_cp)
      indic_linker_pending = false
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

-- Editor cursors are byte offsets so slicing stays cheap, but every movement
-- must land on a grapheme boundary. Reuse the same cluster segmentation as
-- width/wrapping, including combining marks, ZWJ emoji, and flags.
function M.next_grapheme_index(text, cursor)
  text = tostring(text or EMPTY)
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local i = 1
  while i <= #text do
    local _, _, after = next_cluster(text, i)
    local boundary = after - 1
    if boundary > cursor then
      return boundary
    end
    i = after
  end
  return #text
end

function M.previous_grapheme_index(text, cursor)
  text = tostring(text or EMPTY)
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local i = 1
  while i <= #text do
    local start = i - 1
    local _, _, after = next_cluster(text, i)
    if after - 1 >= cursor then
      return start
    end
    i = after
  end
  return #text
end

function M.grapheme_index_at_or_before(text, cursor)
  text = tostring(text or EMPTY)
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local boundary = 0
  local i = 1
  while i <= #text do
    local _, _, after = next_cluster(text, i)
    local next_boundary = after - 1
    if next_boundary > cursor then
      return boundary
    end
    boundary = next_boundary
    i = after
  end
  return #text
end

local function fallback_visible_width(text)
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

function M.visible_width(text)
  if host_visible_width then
    return host_visible_width(text)
  end
  return fallback_visible_width(text)
end

-- Test hooks keep the dependency-free implementation observable even in the
-- normal binary, where the optimized C primitives are installed.
M._debug_fallback_visible_width = fallback_visible_width

function M.pad_line(text, width)
  if host_pad_line then
    return host_pad_line(text, width)
  end
  text = tostring(text or EMPTY)
  width = math.max(1, tonumber(width) or 1)
  return text .. string.rep(" ", math.max(0, width - M.visible_width(text)))
end

local function fallback_byte_index_for_width(text, width)
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

function M.byte_index_for_width(text, width)
  if host_byte_index_for_width then
    return host_byte_index_for_width(text, width)
  end
  return fallback_byte_index_for_width(text, width)
end

M._debug_fallback_byte_index_for_width = fallback_byte_index_for_width

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
  end
  if #active > 0 then
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
  if #out == 0 and (#active > 0 or active.hyperlink ~= nil) then
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
      if col >= start_col and col < finish_col then
        append_active_prefix(out, active)
        out[#out + 1] = seq
      end
      update_active_escape(active, seq)
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
  if rendered ~= "" then
    if active.hyperlink ~= nil then
      rendered = rendered .. OSC8_CLOSE_PREFIX .. (active.hyperlink_terminator or BEL)
    end
    if #active > 0 then
      rendered = rendered .. ANSI_RESET_STYLE
    end
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
        update_active_escape(active, seq)
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
      local suppress_leading = line_width == 0 and soft_wrapped
      if not suppress_leading then
        if line_width > 0 and line_width + space_width + word_width > width then
          emit_line()
          soft_wrapped = true
        else
          line[#line + 1] = string.rep(" ", space_width)
          line_width = line_width + space_width
        end
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
