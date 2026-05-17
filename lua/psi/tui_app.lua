-- Stateful TUI controller for composable Lua-owned screens.
--
-- The app owns root children, focus, overlay layout/compositing, and dirty
-- render requests. The low-level renderer still receives a final line frame.

local component = require("psi.tui_component")
local tui_text = require("psi.tui_text")

local M = {}

local App = {}
App.__index = App

local function clamp(value, low, high)
  value = tonumber(value) or low
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function parse_size(value, reference)
  if value == nil then
    return nil
  end
  if type(value) == "number" then
    return value
  end
  local percent = tostring(value):match("^(%d+%.?%d*)%%$")
  if percent ~= nil then
    return math.floor((math.max(1, reference) * tonumber(percent)) / 100)
  end
  return tonumber(value)
end

local function margin_table(value)
  if type(value) == "number" then
    return { top = value, right = value, bottom = value, left = value }
  end
  return type(value) == "table" and value or {}
end

local function is_visible(app, entry, width, height)
  if entry.hidden then
    return false
  end
  local visible = entry.options and entry.options.visible
  if type(visible) == "function" then
    return not not visible(width, height)
  end
  return true
end

local function non_capturing(opts)
  return not not (opts and (opts.non_capturing or opts.nonCapturing))
end

local function overlay_in_stack(app, entry)
  for _, existing in ipairs(app.overlay_stack) do
    if existing == entry then
      return true
    end
  end
  return false
end

local function focused_overlay(app)
  local focused = app.focused
  if focused == nil then
    return nil
  end
  for _, entry in ipairs(app.overlay_stack) do
    if entry.component == focused then
      return entry
    end
  end
  return nil
end

local function visible_width(text)
  return tui_text.visible_width(text)
end

local function pad_to(text, width)
  return tui_text.pad_line(text or "", math.max(1, width))
end

local function composite_line(base, overlay, start_col, overlay_width, total_width)
  start_col = math.max(0, tonumber(start_col) or 0)
  overlay_width = math.max(1, tonumber(overlay_width) or 1)
  total_width = math.max(1, tonumber(total_width) or 1)

  local before = tui_text.slice_by_columns(base or "", 0, start_col, true)
  local overlay_text = tui_text.slice_by_columns(overlay or "", 0, overlay_width, true)
  local after_col = start_col + overlay_width
  local after_width = math.max(0, total_width - after_col)
  local after = tui_text.slice_by_columns(base or "", after_col, after_width, true)

  before = before .. string.rep(" ", math.max(0, start_col - visible_width(before)))
  overlay_text = overlay_text
    .. string.rep(" ", math.max(0, overlay_width - visible_width(overlay_text)))
  after = after .. string.rep(" ", math.max(0, after_width - visible_width(after)))
  return tui_text.truncate_columns(before .. overlay_text .. after, total_width, true)
end

function App:add_child(child)
  self.root:add_child(child)
  self:request_render()
end

function App:remove_child(child)
  local removed = self.root:remove_child(child)
  if removed then
    self:request_render()
  end
  return removed
end

function App:clear()
  self.root:clear()
  self:request_render()
end

function App:set_focus(child)
  if self.focused == child then
    return
  end
  if self.focused and self.focused.focused ~= nil then
    self.focused.focused = false
  end
  self.focused = child
  if child and child.focused ~= nil then
    child.focused = true
  end
  self:request_render()
end

function App:focused_component()
  return self.focused
end

function App:request_render(force)
  self.dirty = true
  self.force_full = self.force_full or not not force
end

function App:consume_dirty()
  local dirty = self.dirty
  self.dirty = false
  return dirty
end

function App:consume_force_full()
  local force = self.force_full
  self.force_full = false
  return force
end

function App:invalidate()
  self.root:invalidate()
  for _, overlay in ipairs(self.overlay_stack) do
    if overlay.component and type(overlay.component.invalidate) == "function" then
      overlay.component:invalidate()
    end
  end
  self:request_render(true)
end

function App:top_visible_overlay()
  for i = #self.overlay_stack, 1, -1 do
    local entry = self.overlay_stack[i]
    if not non_capturing(entry.options) and is_visible(self, entry, self.width, self.height) then
      return entry
    end
  end
  return nil
end

function App:has_overlay()
  for _, entry in ipairs(self.overlay_stack) do
    if is_visible(self, entry, self.width, self.height) then
      return true
    end
  end
  return false
end

function App:show_overlay(child, opts)
  opts = type(opts) == "table" and opts or {}
  local entry = {
    component = child,
    options = opts,
    pre_focus = self.focused,
    hidden = false,
    focus_order = (self.focus_order or 0) + 1,
  }
  self.focus_order = entry.focus_order
  self.overlay_stack[#self.overlay_stack + 1] = entry
  if not non_capturing(opts) and is_visible(self, entry, self.width, self.height) then
    self:set_focus(child)
  else
    self:request_render()
  end

  local handle = {}
  function handle.hide()
    for i, existing in ipairs(self.overlay_stack) do
      if existing == entry then
        table.remove(self.overlay_stack, i)
        if self.focused == child then
          local top = self:top_visible_overlay()
          self:set_focus(top and top.component or entry.pre_focus)
        else
          self:request_render()
        end
        return
      end
    end
  end
  function handle.set_hidden(hidden)
    hidden = not not hidden
    if entry.hidden == hidden then
      return
    end
    entry.hidden = hidden
    if hidden and self.focused == child then
      local top = self:top_visible_overlay()
      self:set_focus(top and top.component or entry.pre_focus)
    elseif
      not hidden
      and not non_capturing(opts)
      and is_visible(self, entry, self.width, self.height)
    then
      entry.focus_order = (self.focus_order or 0) + 1
      self.focus_order = entry.focus_order
      self:set_focus(child)
    else
      self:request_render()
    end
  end
  function handle.is_hidden()
    return entry.hidden
  end
  function handle.focus()
    if
      not overlay_in_stack(self, entry) or not is_visible(self, entry, self.width, self.height)
    then
      return
    end
    entry.focus_order = (self.focus_order or 0) + 1
    self.focus_order = entry.focus_order
    self:set_focus(child)
  end
  function handle.unfocus()
    if self.focused ~= child then
      return
    end
    local top = self:top_visible_overlay()
    self:set_focus(top and top ~= entry and top.component or entry.pre_focus)
  end
  function handle.is_focused()
    return self.focused == child
  end
  return handle
end

function App:dispatch_key(event)
  local overlay = focused_overlay(self)
  if overlay and not is_visible(self, overlay, self.width, self.height) then
    local top = self:top_visible_overlay()
    self:set_focus(top and top.component or overlay.pre_focus)
  end

  local focused = self.focused
  if focused and type(focused.handle_key) == "function" then
    local consumed = focused:handle_key(event, self)
    if consumed then
      self:request_render()
      return true
    end
  end
  return false
end

function App:resolve_overlay_layout(opts, overlay_height, term_width, term_height)
  opts = type(opts) == "table" and opts or {}
  local margin = margin_table(opts.margin)
  local margin_top = math.max(0, tonumber(margin.top) or 0)
  local margin_right = math.max(0, tonumber(margin.right) or 0)
  local margin_bottom = math.max(0, tonumber(margin.bottom) or 0)
  local margin_left = math.max(0, tonumber(margin.left) or 0)
  local avail_width = math.max(1, term_width - margin_left - margin_right)
  local avail_height = math.max(1, term_height - margin_top - margin_bottom)
  local overlay_width = parse_size(opts.width, term_width) or math.min(80, avail_width)
  if opts.min_width ~= nil then
    overlay_width = math.max(overlay_width, tonumber(opts.min_width) or 1)
  end
  overlay_width = clamp(overlay_width, 1, avail_width)

  local max_height = parse_size(opts.max_height, term_height)
  if max_height ~= nil then
    max_height = clamp(max_height, 1, avail_height)
  end
  local effective_height = max_height and math.min(overlay_height, max_height) or overlay_height
  local anchor = opts.anchor or "center"
  local row
  if opts.row ~= nil then
    if type(opts.row) == "string" and opts.row:find("%%", 1, true) then
      local percent = (parse_size(opts.row, 100) or 50) / 100
      row = margin_top + math.floor(math.max(0, avail_height - effective_height) * percent)
    else
      row = tonumber(opts.row) or 0
    end
  elseif anchor:find("top", 1, true) then
    row = margin_top
  elseif anchor:find("bottom", 1, true) then
    row = margin_top + avail_height - effective_height
  else
    row = margin_top + math.floor((avail_height - effective_height) / 2)
  end

  local col
  if opts.col ~= nil then
    if type(opts.col) == "string" and opts.col:find("%%", 1, true) then
      local percent = (parse_size(opts.col, 100) or 50) / 100
      col = margin_left + math.floor(math.max(0, avail_width - overlay_width) * percent)
    else
      col = tonumber(opts.col) or 0
    end
  elseif anchor:find("right", 1, true) then
    col = margin_left + avail_width - overlay_width
  elseif anchor:find("left", 1, true) then
    col = margin_left
  else
    col = margin_left + math.floor((avail_width - overlay_width) / 2)
  end

  row = row + (tonumber(opts.offset_y or opts.offsetY) or 0)
  col = col + (tonumber(opts.offset_x or opts.offsetX) or 0)
  row = clamp(row, margin_top, math.max(margin_top, term_height - margin_bottom - effective_height))
  col = clamp(col, margin_left, math.max(margin_left, term_width - margin_right - overlay_width))
  return {
    width = overlay_width,
    row = row,
    col = col,
    max_height = max_height,
  }
end

function App:render(width, height)
  width = math.max(1, tonumber(width) or 1)
  height = math.max(1, tonumber(height) or 1)
  self.width = width
  self.height = height

  local lines = self.root:render(width)
  if #self.overlay_stack == 0 then
    return lines
  end

  local entries = {}
  for _, entry in ipairs(self.overlay_stack) do
    if is_visible(self, entry, width, height) then
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    return (a.focus_order or 0) < (b.focus_order or 0)
  end)
  if #entries == 0 then
    return lines
  end

  local rendered = {}
  local working_height = math.max(#lines, height)
  for _, entry in ipairs(entries) do
    local initial = self:resolve_overlay_layout(entry.options, 0, width, height)
    local overlay_lines = entry.component and entry.component:render(initial.width) or {}
    if initial.max_height ~= nil and #overlay_lines > initial.max_height then
      local truncated = {}
      for i = 1, initial.max_height do
        truncated[i] = overlay_lines[i]
      end
      overlay_lines = truncated
    end
    local layout = self:resolve_overlay_layout(entry.options, #overlay_lines, width, height)
    rendered[#rendered + 1] = {
      lines = overlay_lines,
      row = layout.row,
      col = layout.col,
      width = layout.width,
    }
    working_height = math.max(working_height, layout.row + #overlay_lines)
  end

  local out = {}
  for i = 1, working_height do
    out[i] = lines[i] or ""
  end
  local viewport_start = math.max(0, working_height - height)
  for _, overlay in ipairs(rendered) do
    for i, line in ipairs(overlay.lines) do
      local row = viewport_start + overlay.row + i
      if row >= 1 and row <= #out then
        out[row] = composite_line(out[row], line, overlay.col, overlay.width, width)
      end
    end
  end
  for i, line in ipairs(out) do
    out[i] = pad_to(line, width)
  end
  return out
end

function M.new()
  return setmetatable({
    root = component.container({}),
    overlay_stack = {},
    focused = nil,
    focus_order = 0,
    dirty = true,
    force_full = false,
    width = 1,
    height = 1,
  }, App)
end

function M.composite_line(base, overlay, start_col, overlay_width, total_width)
  return composite_line(base, overlay, start_col, overlay_width, total_width)
end

return M
