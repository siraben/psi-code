-- Width-aware markdown component for the TUI transcript.
--
-- The component owns markdown layout, table rendering, and render caching.
-- Callers provide plain markdown text and prefixes; render(width) returns ANSI
-- styled terminal lines that can be composed with other TUI components.

local ansi = require("psi.ansi")
local markdown = require("psi.markdown")

local M = {}

local FRAME_WIDTH_MARGIN = 1
local MIN_WIDTH = 1
local BYTE_SPACE = 32
local BYTE_TAB = 9

local Component = {}
Component.__index = Component

local function strip_ansi(text)
  text = tostring(text or "")
  text = text:gsub("\27%[[%d;?]*[A-Za-z]", "")
  text = text:gsub("\27_[^\7]*\7", "")
  text = text:gsub("\27%][^\7]*\7", "")
  return text
end

local function visible_width(text)
  text = strip_ansi(text)
  local width = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      width = width + 1
    end
    i = i + 1
  end
  return width
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_tabs(text)
  return (tostring(text or ""):gsub("\t", "   "))
end

local function split_lines(text)
  local lines = {}
  text = tostring(text or "")
  text = text:gsub("\n+$", "")
  if text == "" then
    return { "" }
  end
  local cursor = 1
  while true do
    local nl = text:find("\n", cursor, true)
    lines[#lines + 1] = nl and text:sub(cursor, nl - 1) or text:sub(cursor)
    if not nl then
      break
    end
    cursor = nl + 1
  end
  return lines
end

local function display_prefix_width(prefix)
  return visible_width(prefix or "")
end

local function wrap_width(width, prefix)
  local available = (width - FRAME_WIDTH_MARGIN) - display_prefix_width(prefix)
  return math.max(MIN_WIDTH, available)
end

local function is_space_byte(byte)
  return byte == BYTE_SPACE or byte == BYTE_TAB
end

local function byte_index_for_width(text, width)
  if width <= 0 then
    return 0
  end
  local seen = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      seen = seen + 1
      if seen > width then
        return i - 1
      end
    end
    i = i + 1
  end
  return #text
end

local function find_break(text, width)
  if visible_width(text) <= width then
    return #text
  end
  local limit = byte_index_for_width(text, width)
  for i = limit, 1, -1 do
    local byte = text:byte(i)
    if byte ~= nil and is_space_byte(byte) then
      return i - 1
    end
  end
  return math.max(1, limit)
end

local function wrap_plain(text, width)
  text = normalize_tabs(text)
  width = math.max(MIN_WIDTH, tonumber(width) or MIN_WIDTH)
  local out = {}
  local remaining = text
  repeat
    local break_index = find_break(remaining, width)
    local raw = remaining:sub(1, break_index)
    out[#out + 1] = raw:gsub("%s+$", "")
    local next_start = break_index + 1
    while next_start <= #remaining and is_space_byte(remaining:byte(next_start)) do
      next_start = next_start + 1
    end
    remaining = remaining:sub(next_start)
  until remaining == ""
  return out
end

local function parse_cells(line)
  line = tostring(line or "")
  line = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  local start = 1
  while true do
    local sep = line:find("|", start, true)
    cells[#cells + 1] = trim(sep and line:sub(start, sep - 1) or line:sub(start))
    if not sep then
      break
    end
    start = sep + 1
  end
  return cells
end

local function is_table_separator(line)
  if not tostring(line or ""):find("|", 1, true) then
    return false
  end
  local cells = parse_cells(line)
  if #cells < 2 then
    return false
  end
  for _, cell in ipairs(cells) do
    if not cell:match("^:?-?%-+%s*:?$") then
      return false
    end
  end
  return true
end

local function looks_like_table_header(line, next_line)
  return tostring(line or ""):find("|", 1, true) ~= nil and is_table_separator(next_line)
end

local function normalize_row(cells, columns)
  local out = {}
  for i = 1, columns do
    out[i] = cells[i] or ""
  end
  return out
end

local function longest_word_width(text, max_width)
  local longest = 0
  for word in tostring(text or ""):gmatch("%S+") do
    longest = math.max(longest, visible_width(markdown.render_inline(word)))
  end
  if max_width ~= nil then
    longest = math.min(longest, max_width)
  end
  return longest
end

local function styled_cell_width(text)
  return visible_width(markdown.render_inline(text))
end

local function allocate_columns(header, rows, available_width)
  local columns = #header
  local border_overhead = 3 * columns + 1
  local available_for_cells = available_width - border_overhead
  if columns == 0 or available_for_cells < columns then
    return nil
  end

  local natural = {}
  local minimum = {}
  for i = 1, columns do
    natural[i] = math.max(1, styled_cell_width(header[i] or ""))
    minimum[i] = math.max(1, longest_word_width(header[i] or "", 30))
  end
  for _, row in ipairs(rows) do
    for i = 1, columns do
      natural[i] = math.max(natural[i], styled_cell_width(row[i] or ""))
      minimum[i] = math.max(minimum[i], longest_word_width(row[i] or "", 30))
    end
  end

  local min_sum = 0
  for _, width in ipairs(minimum) do
    min_sum = min_sum + width
  end

  if min_sum > available_for_cells then
    local weighted = {}
    local remaining = available_for_cells - columns
    local total_weight = 0
    for i = 1, columns do
      weighted[i] = 1
      total_weight = total_weight + math.max(0, minimum[i] - 1)
    end
    if remaining > 0 then
      local allocated = 0
      for i = 1, columns do
        local weight = math.max(0, minimum[i] - 1)
        local grow = total_weight > 0 and math.floor((weight / total_weight) * remaining) or 0
        weighted[i] = weighted[i] + grow
        allocated = allocated + grow
      end
      local leftover = remaining - allocated
      local index = 1
      while leftover > 0 do
        weighted[index] = weighted[index] + 1
        leftover = leftover - 1
        index = index == columns and 1 or index + 1
      end
    end
    minimum = weighted
    min_sum = available_for_cells
  end

  local natural_sum = 0
  for _, width in ipairs(natural) do
    natural_sum = natural_sum + width
  end
  if natural_sum + border_overhead <= available_width then
    local columns_width = {}
    for i = 1, columns do
      columns_width[i] = math.max(natural[i], minimum[i])
    end
    return columns_width
  end

  local extra = math.max(0, available_for_cells - min_sum)
  local grow_potential = 0
  for i = 1, columns do
    grow_potential = grow_potential + math.max(0, natural[i] - minimum[i])
  end

  local widths = {}
  local allocated = 0
  for i = 1, columns do
    local potential = math.max(0, natural[i] - minimum[i])
    local grow = grow_potential > 0 and math.floor((potential / grow_potential) * extra) or 0
    widths[i] = minimum[i] + grow
    allocated = allocated + widths[i]
  end

  local remaining = available_for_cells - allocated
  while remaining > 0 do
    local grew = false
    for i = 1, columns do
      if remaining <= 0 then
        break
      end
      if widths[i] < natural[i] then
        widths[i] = widths[i] + 1
        remaining = remaining - 1
        grew = true
      end
    end
    if not grew then
      break
    end
  end
  return widths
end

local function border(left, join, right, widths)
  local cells = {}
  for _, width in ipairs(widths) do
    cells[#cells + 1] = string.rep("─", width)
  end
  return left .. "─" .. table.concat(cells, "─" .. join .. "─") .. "─" .. right
end

local function wrap_cell(text, width)
  local wrapped = wrap_plain(text, width)
  local out = {}
  for i, line in ipairs(wrapped) do
    out[i] = markdown.render_inline(line)
  end
  return out
end

local function pad_cell(text, width)
  return text .. string.rep(" ", math.max(0, width - visible_width(text)))
end

local function render_row(cells, widths, style_header)
  local wrapped = {}
  local row_height = 1
  for i = 1, #widths do
    wrapped[i] = wrap_cell(cells[i] or "", widths[i])
    row_height = math.max(row_height, #wrapped[i])
  end
  local lines = {}
  for row = 1, row_height do
    local parts = {}
    for col = 1, #widths do
      local cell = pad_cell(wrapped[col][row] or "", widths[col])
      parts[col] = style_header and ansi.bold(cell) or cell
    end
    lines[#lines + 1] = "│ " .. table.concat(parts, " │ ") .. " │"
  end
  return lines
end

local function render_table_lines(raw_lines, available_width)
  local header = parse_cells(raw_lines[1])
  if #header < 2 then
    return nil
  end
  local rows = {}
  for i = 3, #raw_lines do
    rows[#rows + 1] = normalize_row(parse_cells(raw_lines[i]), #header)
  end
  header = normalize_row(header, #header)

  local widths = allocate_columns(header, rows, available_width)
  if widths == nil then
    return nil
  end

  local out = {
    border("┌", "┬", "┐", widths),
  }
  for _, line in ipairs(render_row(header, widths, true)) do
    out[#out + 1] = line
  end
  out[#out + 1] = border("├", "┼", "┤", widths)
  for row_index, row in ipairs(rows) do
    for _, line in ipairs(render_row(row, widths, false)) do
      out[#out + 1] = line
    end
    if row_index < #rows then
      out[#out + 1] = border("├", "┼", "┤", widths)
    end
  end
  out[#out + 1] = border("└", "┴", "┘", widths)
  return out
end

local function is_fence_line(text)
  return text:match("^%s*```") ~= nil or text:match("^%s*~~~") ~= nil
end

local function render_wrapped_line(out, source_line, prefix, rest_prefix, width, in_code_fence)
  local remaining = normalize_tabs(source_line)
  repeat
    local break_index = find_break(remaining, wrap_width(width, prefix))
    local chunk = remaining:sub(1, break_index):gsub("%s+$", "")
    out[#out + 1] = markdown.render_line(prefix .. chunk, in_code_fence)
    local next_start = break_index + 1
    while next_start <= #remaining and is_space_byte(remaining:byte(next_start)) do
      next_start = next_start + 1
    end
    remaining = remaining:sub(next_start)
    prefix = rest_prefix or ""
  until remaining == ""
end

local function render_text(self, width)
  local source_lines = split_lines(self.text)
  local out = {}
  local prefix = self.prefix_first or ""
  local rest_prefix = self.prefix_rest or ""
  local fence_state = false
  local i = 1

  while i <= #source_lines do
    local line = source_lines[i]
    local next_line = source_lines[i + 1]
    if not fence_state and looks_like_table_header(line, next_line) then
      local raw_table = { line, next_line }
      i = i + 2
      while
        i <= #source_lines
        and source_lines[i] ~= ""
        and tostring(source_lines[i]):find("|", 1, true) ~= nil
      do
        raw_table[#raw_table + 1] = source_lines[i]
        i = i + 1
      end

      local table_width = wrap_width(width, prefix)
      local rendered = render_table_lines(raw_table, table_width)
      if rendered ~= nil then
        for _, table_line in ipairs(rendered) do
          out[#out + 1] = (prefix or "") .. table_line
          prefix = rest_prefix
        end
      else
        for _, raw_line in ipairs(raw_table) do
          render_wrapped_line(out, raw_line, prefix or "", rest_prefix, width, false)
          prefix = rest_prefix
        end
      end
    else
      local fence_line = is_fence_line(line)
      local line_fence_flag
      if fence_line then
        line_fence_flag = true
        fence_state = not fence_state
      else
        line_fence_flag = fence_state
      end
      render_wrapped_line(out, line, prefix or "", rest_prefix, width, line_fence_flag)
      prefix = rest_prefix
      i = i + 1
    end
  end

  return out
end

function Component:set_text(text)
  text = tostring(text or "")
  if self.text ~= text then
    self.text = text
    self:invalidate()
  end
end

function Component:set_prefixes(first, rest)
  first = tostring(first or "")
  rest = tostring(rest or "")
  if self.prefix_first ~= first or self.prefix_rest ~= rest then
    self.prefix_first = first
    self.prefix_rest = rest
    self:invalidate()
  end
end

function Component:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_text = nil
  self.cache_prefix_first = nil
  self.cache_prefix_rest = nil
  self.cache_lines = nil
end

function Component:render(width)
  width = math.max(MIN_WIDTH, tonumber(width) or MIN_WIDTH)
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_text == self.text
    and self.cache_prefix_first == self.prefix_first
    and self.cache_prefix_rest == self.prefix_rest
  then
    return self.cache_lines
  end
  local lines = render_text(self, width)
  self.cache_width = width
  self.cache_text = self.text
  self.cache_prefix_first = self.prefix_first
  self.cache_prefix_rest = self.prefix_rest
  self.cache_lines = lines
  return lines
end

function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    text = tostring(opts.text or ""),
    prefix_first = tostring(opts.prefix_first or ""),
    prefix_rest = tostring(opts.prefix_rest or ""),
    generation = 0,
  }, Component)
end

function M.render_table(lines, width)
  return render_table_lines(type(lines) == "table" and lines or {}, math.max(1, tonumber(width) or 1))
end

return M
