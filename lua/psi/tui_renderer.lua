-- Differential line renderer for the Lua-owned TUI.
--
-- The renderer accepts logical screen lines and owns the previous-frame cache.
-- It keeps full redraw as the conservative fallback and uses changed-row writes
-- only when the terminal dimensions are stable.

local tui_text = require("psi.tui_text")

local M = {}

local ESC = string.char(27)
local CSI = ESC .. "["
local RESET = CSI .. "0m"
local OSC_RESET = ESC .. "]8;;" .. string.char(7)
local LINE_RESET = RESET .. OSC_RESET
local SYNC_BEGIN = CSI .. "?2026h"
local SYNC_END = CSI .. "?2026l"
local HIDE_CURSOR = CSI .. "?25l"
local SHOW_CURSOR = CSI .. "?25h"

local CURSOR_MARKER = ESC .. "_psi:c" .. string.char(7)

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function normalize_lines(lines, height)
  local out = {}
  height = math.max(1, tonumber(height) or 1)
  lines = type(lines) == "table" and lines or {}
  for row = 1, height do
    out[row] = tostring(lines[row] or "")
  end
  return out
end

local function apply_line_resets(lines)
  local out = {}
  for row, line in ipairs(lines) do
    out[row] = tostring(line or "") .. LINE_RESET
  end
  return out
end

local function absolute_frame(lines)
  local frame = {}
  for row, line in ipairs(lines) do
    frame[#frame + 1] = CSI .. tostring(row) .. ";1H" .. CSI .. "2K" .. line
  end
  return table.concat(frame)
end

local function find_changed_span(previous, next_lines)
  local first
  local last
  local count = math.max(#previous, #next_lines)
  for i = 1, count do
    if (previous[i] or "") ~= (next_lines[i] or "") then
      first = first or i
      last = i
    end
  end
  return first, last
end

local function write_diff(lines, first, last, cursor_row, cursor_col, cursor_visible)
  local out = { SYNC_BEGIN, HIDE_CURSOR }
  if first ~= nil and last ~= nil then
    for row = first, last do
      out[#out + 1] = CSI .. tostring(row) .. ";1H"
      out[#out + 1] = CSI .. "2K"
      out[#out + 1] = lines[row] or ""
      out[#out + 1] = RESET
    end
  end
  if cursor_visible then
    out[#out + 1] = CSI .. tostring(cursor_row) .. ";" .. tostring(cursor_col) .. "H"
    out[#out + 1] = SHOW_CURSOR
  else
    out[#out + 1] = HIDE_CURSOR
  end
  out[#out + 1] = SYNC_END
  psi.stdout_write(table.concat(out))
end

function M.new()
  return {
    previous_lines = {},
    previous_width = nil,
    previous_height = nil,
    previous_cursor_row = nil,
    previous_cursor_col = nil,
    previous_cursor_visible = nil,
    full_redraws = 0,
    diff_redraws = 0,
    skipped_redraws = 0,
    last_changed_first = nil,
    last_changed_last = nil,
    last_mode = nil,
    last_full_reason = nil,
  }
end

function M.reset(renderer)
  if type(renderer) ~= "table" then
    return
  end
  renderer.previous_lines = {}
  renderer.previous_width = nil
  renderer.previous_height = nil
  renderer.previous_cursor_row = nil
  renderer.previous_cursor_col = nil
  renderer.previous_cursor_visible = nil
  renderer.last_changed_first = nil
  renderer.last_changed_last = nil
  renderer.last_mode = nil
  renderer.last_full_reason = nil
end

function M.render(renderer, lines, opts)
  renderer = type(renderer) == "table" and renderer or M.new()
  opts = type(opts) == "table" and opts or {}

  local raw_lines = type(lines) == "table" and lines or {}
  local width = math.max(1, tonumber(opts.width) or 1)
  local height = math.max(1, tonumber(opts.height) or #raw_lines or 1)
  local next_lines, marker_cursor = M.extract_cursor(normalize_lines(raw_lines, height))
  next_lines = apply_line_resets(next_lines)
  local cursor_row = clamp(tonumber(opts.cursor_row) or 1, 1, height)
  local cursor_col = math.max(1, tonumber(opts.cursor_col) or 1)
  local cursor_visible = not not opts.cursor_visible
  if marker_cursor ~= nil then
    cursor_row = clamp(marker_cursor.row, 1, height)
    cursor_col = math.max(1, marker_cursor.col)
  end

  local can_diff = type(psi.stdout_write) == "function"
  local reason
  if opts.force_full then
    reason = "forced"
  elseif renderer.previous_width ~= width then
    reason = "width"
  elseif renderer.previous_height ~= height then
    reason = "height"
  elseif #renderer.previous_lines == 0 then
    reason = "first"
  elseif not can_diff then
    reason = "no-writer"
  end

  local first, last = find_changed_span(renderer.previous_lines, next_lines)

  renderer.last_changed_first = first
  renderer.last_changed_last = last

  local cursor_changed = renderer.previous_cursor_row ~= cursor_row
    or renderer.previous_cursor_col ~= cursor_col
    or renderer.previous_cursor_visible ~= cursor_visible

  if first == nil and reason == nil and not cursor_changed then
    renderer.skipped_redraws = renderer.skipped_redraws + 1
    renderer.last_mode = "skip"
    renderer.last_full_reason = nil
    return renderer
  end

  if reason ~= nil then
    renderer.full_redraws = renderer.full_redraws + 1
    renderer.last_mode = "full"
    renderer.last_full_reason = reason
    if type(psi.tui_render_frame) == "function" then
      psi.tui_render_frame(absolute_frame(next_lines), cursor_row, cursor_col, cursor_visible)
    elseif type(psi.tui_draw_raw_line) == "function" then
      psi.tui_set_cursor(1, 1, false)
      for row, line in ipairs(next_lines) do
        psi.tui_draw_raw_line(row, line)
      end
      psi.tui_set_cursor(cursor_row, cursor_col, cursor_visible)
      psi.tui_refresh()
    end
  else
    renderer.diff_redraws = renderer.diff_redraws + 1
    renderer.last_mode = "diff"
    renderer.last_full_reason = nil
    write_diff(next_lines, first, last, cursor_row, cursor_col, cursor_visible)
  end

  renderer.previous_lines = next_lines
  renderer.previous_width = width
  renderer.previous_height = height
  renderer.previous_cursor_row = cursor_row
  renderer.previous_cursor_col = cursor_col
  renderer.previous_cursor_visible = cursor_visible
  return renderer
end

function M.cursor_marker()
  return CURSOR_MARKER
end

function M.extract_cursor(lines)
  lines = type(lines) == "table" and lines or {}
  local out = {}
  local cursor
  for row, line in ipairs(lines) do
    line = tostring(line or "")
    local start_pos, end_pos = line:find(CURSOR_MARKER, 1, true)
    if start_pos ~= nil and cursor == nil then
      cursor = { row = row, col = tui_text.visible_width(line:sub(1, start_pos - 1)) + 1 }
      line = line:sub(1, start_pos - 1) .. line:sub(end_pos + 1)
    end
    out[row] = line
  end
  return out, cursor
end

return M
