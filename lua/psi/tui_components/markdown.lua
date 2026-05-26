-- Width-aware markdown component for the TUI transcript.
--
-- The component owns markdown layout, table rendering, and render caching.
-- Callers provide plain markdown text and prefixes; render(width) returns ANSI
-- styled terminal lines that can be composed with other TUI components.

local ansi = require("psi.ansi")
local markdown = require("psi.markdown")
local tui_component = require("psi.tui_component")
local tui_text = require("psi.tui_text")

local M = {}

local FRAME_WIDTH_MARGIN = 1
local MIN_WIDTH = 1
local BYTE_SPACE = 32
local BYTE_TAB = 9

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
  return tui_text.visible_width(prefix or "")
end

local function wrap_width(width, prefix)
  local available = (width - FRAME_WIDTH_MARGIN) - display_prefix_width(prefix)
  return math.max(MIN_WIDTH, available)
end

local function is_space_byte(byte)
  return byte == BYTE_SPACE or byte == BYTE_TAB
end

local function find_break(text, width)
  if tui_text.visible_width(text) <= width then
    return #text
  end
  local limit = tui_text.byte_index_for_width(text, width)
  for i = limit, 1, -1 do
    local byte = text:byte(i)
    if byte ~= nil and is_space_byte(byte) then
      return i - 1
    end
  end
  return math.max(1, limit)
end

local function parse_cells(line)
  line = tostring(line or "")
  local cells = {}
  local cell = {}
  local escaped = false
  local in_code = false
  local i = 1

  while i <= #line do
    local ch = line:sub(i, i)
    if escaped then
      if ch == "|" then
        cell[#cell + 1] = ch
      else
        cell[#cell + 1] = "\\" .. ch
      end
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == "`" then
      in_code = not in_code
      cell[#cell + 1] = ch
    elseif ch == "|" and not in_code then
      cells[#cells + 1] = trim(table.concat(cell))
      cell = {}
    else
      cell[#cell + 1] = ch
    end
    i = i + 1
  end

  if escaped then
    cell[#cell + 1] = "\\"
  end
  cells[#cells + 1] = trim(table.concat(cell))

  if cells[1] == "" then
    table.remove(cells, 1)
  end
  if cells[#cells] == "" then
    table.remove(cells)
  end
  return cells
end

local function has_table_pipe(line)
  line = tostring(line or "")
  local escaped = false
  local in_code = false
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == "`" then
      in_code = not in_code
    elseif ch == "|" and not in_code then
      return true
    end
    i = i + 1
  end
  return false
end

local function has_leading_pipe(line)
  return tostring(line or ""):match("^%s*|") ~= nil
end

local function has_trailing_pipe(line)
  return tostring(line or ""):match("|%s*$") ~= nil
end

local function is_table_separator(line)
  if not has_table_pipe(line) then
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

local is_table_row

local function parse_gfm_table_block(lines, start_index)
  lines = type(lines) == "table" and lines or {}
  start_index = tonumber(start_index) or 1
  local line = lines[start_index]
  local next_line = lines[start_index + 1]
  if not has_table_pipe(line) or not is_table_separator(next_line) then
    return nil
  end
  local header = parse_cells(line)
  local separator = parse_cells(next_line)
  if #header < 2 or #separator ~= #header then
    return nil
  end
  local info = {
    columns = #header,
    leading_pipe = has_leading_pipe(line),
    trailing_pipe = has_trailing_pipe(line),
  }
  local raw_table = { line, next_line }
  local index = start_index + 2
  while index <= #lines and is_table_row(lines[index], info) do
    raw_table[#raw_table + 1] = lines[index]
    index = index + 1
  end
  return {
    raw_lines = raw_table,
    next_index = index,
  }
end

function is_table_row(line, table_info)
  if line == "" or not has_table_pipe(line) then
    return false
  end
  if table_info.leading_pipe and not has_leading_pipe(line) then
    return false
  end
  if table_info.trailing_pipe and not has_trailing_pipe(line) then
    return false
  end
  return #parse_cells(line) == table_info.columns
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
    longest = math.max(longest, tui_text.visible_width(markdown.render_inline(word)))
  end
  if max_width ~= nil then
    longest = math.min(longest, max_width)
  end
  return longest
end

local function styled_cell_width(text)
  return tui_text.visible_width(markdown.render_inline(text))
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
  local styled = markdown.render_inline(text)
  if tui_text.visible_width(styled) <= width then
    return { styled }
  end
  return tui_text.wrap_ansi(styled, width)
end

local function pad_cell(text, width)
  return text .. string.rep(" ", math.max(0, width - tui_text.visible_width(text)))
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
  local separator = parse_cells(raw_lines[2])
  if not is_table_separator(raw_lines[2]) or #separator ~= #header then
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

local function is_blank_line(text)
  return tostring(text or ""):match("^%s*$") ~= nil
end

local function is_horizontal_rule(text)
  return text:match("^%s*%-%-%-+%s*$") ~= nil
    or text:match("^%s*%*%*%*+%s*$") ~= nil
    or text:match("^%s*___+%s*$") ~= nil
end

local function is_structural_line(text)
  text = tostring(text or "")
  return is_fence_line(text)
    or is_blank_line(text)
    or is_horizontal_rule(text)
    or text:match("^%s*#+%s+") ~= nil
    or text:match("^%s*[%-%*%+]%s+") ~= nil
    or text:match("^%s*%d+%.%s+") ~= nil
    or text:match("^%s*>%s?") ~= nil
end

local function render_wrapped_styled(out, styled, prefix, rest_prefix, width)
  local first_width = wrap_width(width, prefix)
  local rest_width = wrap_width(width, rest_prefix or "")
  local line_width = math.max(MIN_WIDTH, math.min(first_width, rest_width))
  local wrapped = tui_text.wrap_ansi(styled, line_width)
  for _, line in ipairs(wrapped) do
    out[#out + 1] = (prefix or "") .. line
    prefix = rest_prefix or ""
  end
end

local function styled_structural_prefix(raw_prefix)
  local rendered = markdown.render_line(raw_prefix, false)
  if tui_text.visible_width(rendered) == tui_text.visible_width(raw_prefix) then
    return rendered
  end
  return raw_prefix
end

local function render_prefixed_inline(out, body, first_prefix, continuation_prefix, width)
  local body_width = math.max(
    MIN_WIDTH,
    math.min(
      width - FRAME_WIDTH_MARGIN - tui_text.visible_width(first_prefix),
      width - FRAME_WIDTH_MARGIN - tui_text.visible_width(continuation_prefix)
    )
  )
  local wrapped = tui_text.wrap_ansi(markdown.render_inline(body), body_width)
  for _, line in ipairs(wrapped) do
    out[#out + 1] = first_prefix .. line
    first_prefix = continuation_prefix
  end
end

local function render_structural_wrapped_line(out, source_line, prefix, rest_prefix, width)
  local line = normalize_tabs(source_line)
  prefix = prefix or ""
  rest_prefix = rest_prefix or ""
  local indent, bullet, bullet_body = line:match("^(%s*)([%-%*%+])%s+(.*)$")
  if indent ~= nil then
    local raw_first = indent .. bullet .. " "
    local raw_rest = indent .. string.rep(" ", tui_text.visible_width(bullet .. " "))
    render_prefixed_inline(
      out,
      bullet_body,
      prefix .. styled_structural_prefix(raw_first),
      rest_prefix .. raw_rest,
      width
    )
    return true
  end

  local num_indent, num, num_body = line:match("^(%s*)(%d+%.)%s+(.*)$")
  if num_indent ~= nil then
    local raw_first = num_indent .. num .. " "
    local raw_rest = num_indent .. string.rep(" ", tui_text.visible_width(num .. " "))
    render_prefixed_inline(
      out,
      num_body,
      prefix .. styled_structural_prefix(raw_first),
      rest_prefix .. raw_rest,
      width
    )
    return true
  end

  local quote_indent, quote_body = line:match("^(%s*)>%s?(.*)$")
  if quote_indent ~= nil then
    local quote_prefix = quote_indent .. styled_structural_prefix("> ")
    render_prefixed_inline(
      out,
      quote_body,
      prefix .. quote_prefix,
      rest_prefix .. quote_prefix,
      width
    )
    return true
  end

  return false
end

local function render_wrapped_line(out, source_line, prefix, rest_prefix, width, in_code_fence)
  if
    not in_code_fence
    and render_structural_wrapped_line(out, source_line, prefix, rest_prefix, width)
  then
    return
  end
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

local function collect_paragraph(lines, start_index)
  local parts = {}
  local i = start_index
  while i <= #lines do
    local line = lines[i]
    if is_structural_line(line) or parse_gfm_table_block(lines, i) ~= nil then
      break
    end
    parts[#parts + 1] = trim(normalize_tabs(line))
    i = i + 1
  end
  return table.concat(parts, " "), i
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
    local table_block = not fence_state and parse_gfm_table_block(source_lines, i) or nil
    if table_block then
      i = table_block.next_index
      local table_width = wrap_width(width, prefix)
      local rendered = render_table_lines(table_block.raw_lines, table_width)
      if rendered ~= nil then
        for _, table_line in ipairs(rendered) do
          out[#out + 1] = (prefix or "") .. table_line
          prefix = rest_prefix
        end
      else
        for _, raw_line in ipairs(table_block.raw_lines) do
          render_wrapped_line(out, raw_line, prefix or "", rest_prefix, width, false)
          prefix = rest_prefix
        end
      end
    elseif not fence_state and not is_structural_line(line) then
      local paragraph, next_index = collect_paragraph(source_lines, i)
      render_wrapped_styled(
        out,
        markdown.render_inline(paragraph),
        prefix or "",
        rest_prefix,
        width
      )
      prefix = rest_prefix
      i = next_index
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

local function set_text(self, text)
  text = tostring(text or "")
  if self.text ~= text then
    self.text = text
    self:invalidate()
  end
end

local function set_prefixes(self, first, rest)
  first = tostring(first or "")
  rest = tostring(rest or "")
  if self.prefix_first ~= first or self.prefix_rest ~= rest then
    self.prefix_first = first
    self.prefix_rest = rest
    self:invalidate()
  end
end

local function invalidate(self)
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_text = nil
  self.cache_prefix_first = nil
  self.cache_prefix_rest = nil
  self.cache_lines = nil
end

local function render_component(self, width)
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
  local component = tui_component.new()
  component.text = tostring(opts.text or "")
  component.prefix_first = tostring(opts.prefix_first or "")
  component.prefix_rest = tostring(opts.prefix_rest or "")
  component.set_text = set_text
  component.set_prefixes = set_prefixes
  component.invalidate = invalidate
  component.render = render_component
  return component
end

function M.render_table(lines, width)
  return render_table_lines(
    type(lines) == "table" and lines or {},
    math.max(1, tonumber(width) or 1)
  )
end

return M
