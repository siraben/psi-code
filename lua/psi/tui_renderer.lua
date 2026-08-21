-- Line-frame renderer for the Lua-owned TUI.
--
-- The runtime builds complete logical frames. The renderer owns normalization,
-- cursor extraction, previous-frame state, and the choice between full redraw,
-- differential redraw, and no-op frames.

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

local Renderer = {}
Renderer.__index = Renderer

local Backend = {}
Backend.__index = Backend

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function cursor_from_frame(frame, height, width)
  local cursor = type(frame.cursor) == "table" and frame.cursor or {}
  return {
    row = clamp(tonumber(cursor.row) or tonumber(frame.cursor_row) or 1, 1, height),
    col = clamp(tonumber(cursor.col) or tonumber(frame.cursor_col) or 1, 1, width),
    visible = not not (cursor.visible or frame.cursor_visible),
  }
end

local function absolute_frame(lines, top)
  local frame = {}
  top = math.max(1, tonumber(top) or 1)
  for row, line in ipairs(lines) do
    frame[#frame + 1] = CSI .. tostring(top + row - 1) .. ";1H" .. CSI .. "2K" .. line
  end
  return table.concat(frame)
end

local function move_to_row(out, from_row, to_row)
  from_row = math.max(1, tonumber(from_row) or 1)
  to_row = math.max(1, tonumber(to_row) or 1)
  if to_row < from_row then
    out[#out + 1] = CSI .. tostring(from_row - to_row) .. "A"
  elseif to_row > from_row then
    out[#out + 1] = CSI .. tostring(to_row - from_row) .. "B"
  end
  out[#out + 1] = "\r"
  return to_row
end

local function finish_relative_frame(out, current_row, cursor)
  current_row = move_to_row(out, current_row, cursor.row)
  out[#out + 1] = CSI .. tostring(cursor.col) .. "G"
  out[#out + 1] = cursor.visible and SHOW_CURSOR or HIDE_CURSOR
  out[#out + 1] = SYNC_END
  return current_row
end

local function find_changed_ranges(previous, next_lines)
  local ranges = {}
  local first
  local last
  local row = 1
  local count = math.max(#previous, #next_lines)

  while row <= count do
    if (previous[row] or "") ~= (next_lines[row] or "") then
      local start = row
      while row <= count and (previous[row] or "") ~= (next_lines[row] or "") do
        row = row + 1
      end
      ranges[#ranges + 1] = { first = start, last = row - 1 }
      first = first or start
      last = row - 1
    else
      row = row + 1
    end
  end

  return ranges, first, last
end

local function normalize_frame(frame)
  frame = type(frame) == "table" and frame or {}
  local raw_lines = type(frame.lines) == "table" and frame.lines or {}
  local width = math.max(1, tonumber(frame.width) or 1)
  local height = math.max(1, tonumber(frame.height) or #raw_lines or 1)
  local top = math.max(1, tonumber(frame.top) or tonumber(frame.viewport_top) or 1)
  local cursor = cursor_from_frame(frame, height, width)

  -- Single pass: stringify, extract the first cursor marker, and append the
  -- per-line style reset without building intermediate copies of the frame.
  local lines = {}
  local marker_found = false
  for row = 1, height do
    local line = tostring(raw_lines[row] or "")
    -- Components return one physical line per array element. Guard that
    -- contract here so an extension or future component cannot smuggle a
    -- cursor-moving CR (or an unexpected LF) into the terminal backend.
    line = line:gsub("\r\n", " "):gsub("[\r\n]", " ")
    if not marker_found then
      local start_pos, end_pos = line:find(CURSOR_MARKER, 1, true)
      if start_pos ~= nil then
        marker_found = true
        cursor.row = clamp(row, 1, height)
        cursor.col = clamp(tui_text.visible_width(line:sub(1, start_pos - 1)) + 1, 1, width)
        line = line:sub(1, start_pos - 1) .. line:sub(end_pos + 1)
      end
    end
    lines[row] = line .. LINE_RESET
  end

  return {
    width = width,
    height = height,
    top = top,
    lines = lines,
    cursor = cursor,
    force_full = not not frame.force_full,
  }
end

function Backend:can_diff()
  return type(psi.tui_write) == "function"
    or (self.use_line_primitive and type(psi.tui_render_lines) == "function")
    or type(psi.stdout_write) == "function"
end

function Backend:reset()
  self.cursor_row = nil
  self.height = nil
end

function Backend:finish()
  if self.cursor_row == nil or type(psi.tui_write) ~= "function" then
    return
  end
  local out = { RESET, SHOW_CURSOR }
  move_to_row(out, self.cursor_row, self.height or self.cursor_row)
  out[#out + 1] = "\r\n"
  psi.tui_write(table.concat(out))
  self.cursor_row = nil
  self.height = nil
end

function Backend:render_full(frame)
  local cursor = frame.cursor

  if not self.use_line_primitive and type(psi.tui_write) == "function" then
    local out = { SYNC_BEGIN, HIDE_CURSOR }
    local current_row = self.cursor_row
    if current_row ~= nil then
      current_row = move_to_row(out, current_row, 1)
    else
      current_row = 1
      out[#out + 1] = "\r"
    end
    out[#out + 1] = CSI .. "J"
    for row, line in ipairs(frame.lines) do
      out[#out + 1] = CSI .. "2K"
      out[#out + 1] = line
      if row < #frame.lines then
        out[#out + 1] = "\r\n"
        current_row = current_row + 1
      end
    end
    self.cursor_row = finish_relative_frame(out, current_row, cursor)
    self.height = frame.height
    psi.tui_write(table.concat(out))
  elseif self.use_line_primitive and type(psi.tui_render_lines) == "function" then
    psi.tui_render_lines(frame.lines, cursor.row, cursor.col, cursor.visible, true, frame.top)
  elseif type(psi.tui_render_frame) == "function" then
    psi.tui_render_frame(
      absolute_frame(frame.lines, frame.top),
      frame.top + cursor.row - 1,
      cursor.col,
      cursor.visible
    )
  elseif type(psi.tui_draw_raw_line) == "function" then
    psi.tui_set_cursor(frame.top, 1, false)
    for row, line in ipairs(frame.lines) do
      psi.tui_draw_raw_line(frame.top + row - 1, line)
    end
    psi.tui_set_cursor(frame.top + cursor.row - 1, cursor.col, cursor.visible)
    psi.tui_refresh()
  end
end

function Backend:render_diff(frame, ranges)
  local cursor = frame.cursor

  if not self.use_line_primitive and type(psi.tui_write) == "function" then
    local out = { SYNC_BEGIN, HIDE_CURSOR }
    local current_row = self.cursor_row or 1
    for _, range in ipairs(ranges) do
      for row = range.first, range.last do
        current_row = move_to_row(out, current_row, row)
        out[#out + 1] = CSI .. "2K"
        out[#out + 1] = frame.lines[row] or ""
      end
    end
    self.cursor_row = finish_relative_frame(out, current_row, cursor)
    self.height = frame.height
    psi.tui_write(table.concat(out))
    return
  end

  if self.use_line_primitive and type(psi.tui_render_lines) == "function" then
    psi.tui_render_lines(frame.lines, cursor.row, cursor.col, cursor.visible, false, frame.top)
    return
  end

  local out = { SYNC_BEGIN, HIDE_CURSOR }

  for _, range in ipairs(ranges) do
    for row = range.first, range.last do
      out[#out + 1] = CSI .. tostring(frame.top + row - 1) .. ";1H"
      out[#out + 1] = CSI .. "2K"
      out[#out + 1] = frame.lines[row] or ""
      out[#out + 1] = RESET
    end
  end

  if cursor.visible then
    out[#out + 1] = CSI
      .. tostring(frame.top + cursor.row - 1)
      .. ";"
      .. tostring(cursor.col)
      .. "H"
    out[#out + 1] = SHOW_CURSOR
  else
    out[#out + 1] = HIDE_CURSOR
  end
  out[#out + 1] = SYNC_END
  psi.stdout_write(table.concat(out))
end

local function terminal_backend(opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    use_line_primitive = not not opts.line_primitive,
  }, Backend)
end

local function cursor_changed(renderer, cursor)
  return renderer.previous_cursor_row ~= cursor.row
    or renderer.previous_cursor_col ~= cursor.col
    or renderer.previous_cursor_visible ~= cursor.visible
end

function Renderer:reset(reason)
  self.previous_lines = {}
  self.previous_width = nil
  self.previous_height = nil
  self.previous_top = nil
  self.previous_cursor_row = nil
  self.previous_cursor_col = nil
  self.previous_cursor_visible = nil
  self.last_changed_first = nil
  self.last_changed_last = nil
  self.last_changed_ranges = {}
  self.last_mode = nil
  self.last_full_reason = reason
  if type(self.backend.reset) == "function" then
    self.backend:reset()
  end
end

function Renderer:render(frame)
  local next_frame = normalize_frame(frame)
  local reason
  local ranges, first, last = find_changed_ranges(self.previous_lines, next_frame.lines)
  local cursor_has_changed = cursor_changed(self, next_frame.cursor)

  if next_frame.force_full then
    reason = "forced"
  elseif self.previous_width ~= next_frame.width then
    reason = "width"
  elseif self.previous_height ~= next_frame.height then
    reason = "height"
  elseif self.previous_top ~= next_frame.top then
    reason = "top"
  elseif #self.previous_lines == 0 then
    reason = "first"
  elseif not self.backend:can_diff() then
    reason = "no-writer"
  end

  self.last_changed_first = first
  self.last_changed_last = last
  self.last_changed_ranges = ranges

  if #ranges == 0 and reason == nil and not cursor_has_changed then
    self.skipped_redraws = self.skipped_redraws + 1
    self.last_mode = "skip"
    self.last_full_reason = nil
    return self
  end

  if reason ~= nil then
    self.full_redraws = self.full_redraws + 1
    self.last_mode = "full"
    self.last_full_reason = reason
    self.backend:render_full(next_frame)
  else
    self.diff_redraws = self.diff_redraws + 1
    self.last_mode = "diff"
    self.last_full_reason = nil
    self.backend:render_diff(next_frame, ranges)
  end

  self.previous_lines = next_frame.lines
  self.previous_width = next_frame.width
  self.previous_height = next_frame.height
  self.previous_top = next_frame.top
  self.previous_cursor_row = next_frame.cursor.row
  self.previous_cursor_col = next_frame.cursor.col
  self.previous_cursor_visible = next_frame.cursor.visible
  return self
end

function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    backend = opts.backend or terminal_backend(opts),
    previous_lines = {},
    previous_width = nil,
    previous_height = nil,
    previous_top = nil,
    previous_cursor_row = nil,
    previous_cursor_col = nil,
    previous_cursor_visible = nil,
    full_redraws = 0,
    diff_redraws = 0,
    skipped_redraws = 0,
    last_changed_first = nil,
    last_changed_last = nil,
    last_changed_ranges = {},
    last_mode = nil,
    last_full_reason = nil,
  }, Renderer)
end

function M.reset(renderer, reason)
  if type(renderer) == "table" and type(renderer.reset) == "function" then
    renderer:reset(reason)
  end
end

function M.finish(renderer)
  if
    type(renderer) == "table"
    and type(renderer.backend) == "table"
    and type(renderer.backend.finish) == "function"
  then
    renderer.backend:finish()
  end
end

function M.render(renderer, lines, opts)
  renderer = type(renderer) == "table" and renderer or M.new()
  opts = type(opts) == "table" and opts or {}
  return renderer:render({
    width = opts.width,
    height = opts.height,
    top = opts.top or opts.viewport_top,
    lines = lines,
    cursor = {
      row = opts.cursor_row,
      col = opts.cursor_col,
      visible = opts.cursor_visible,
    },
    force_full = opts.force_full,
  })
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
