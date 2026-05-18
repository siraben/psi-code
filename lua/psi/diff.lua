-- psi.diff: edit diff generation shared by tools and TUI renderers.

local prelude = require("psi.prelude")
local ansi = require("psi.ansi")

local M = {}

local UTF8_BOM = "\239\187\191"
local DEFAULT_CONTEXT_LINES = 4
local MAX_LCS_CELLS = 250000

local function split_lines(text)
  return prelude.split(text or "", "\n")
end

local function detect_line_ending(text)
  local crlf = text and text:find("\r\n", 1, true) or nil
  local lf = text and text:find("\n", 1, true) or nil
  if lf == nil or crlf == nil then
    return "\n"
  end
  return crlf < lf and "\r\n" or "\n"
end

local function normalize_to_lf(text)
  return ((text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function restore_line_endings(text, ending)
  if ending == "\r\n" then
    return (text or ""):gsub("\n", "\r\n")
  end
  return text or ""
end

local function normalize_with_raw_map(text)
  text = text or ""
  local normalized, raw_start, raw_end = {}, {}, {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte == 13 then
      local next_i = i + 1
      if text:byte(next_i) == 10 then
        normalized[#normalized + 1] = "\n"
        raw_start[#normalized] = i
        raw_end[#normalized] = next_i
        i = next_i + 1
      else
        normalized[#normalized + 1] = "\n"
        raw_start[#normalized] = i
        raw_end[#normalized] = i
        i = i + 1
      end
    else
      normalized[#normalized + 1] = text:sub(i, i)
      raw_start[#normalized] = i
      raw_end[#normalized] = i
      i = i + 1
    end
  end
  return table.concat(normalized), raw_start, raw_end
end

local function strip_bom(text)
  text = text or ""
  if text:sub(1, #UTF8_BOM) == UTF8_BOM then
    return UTF8_BOM, text:sub(#UTF8_BOM + 1)
  end
  return "", text
end

local function count_occurrences(content, needle)
  if needle == "" then
    return 0
  end
  local count = 0
  local start = 1
  while true do
    local i, j = content:find(needle, start, true)
    if not i then
      return count
    end
    count = count + 1
    start = j + 1
  end
end

local function not_found_error(path, index, total)
  if total == 1 then
    return "Could not find the exact text in "
      .. tostring(path)
      .. ". The old text must match exactly including all whitespace and newlines."
  end
  return "Could not find edits["
    .. tostring(index)
    .. "] in "
    .. tostring(path)
    .. ". The oldText must match exactly including all whitespace and newlines."
end

local function duplicate_error(path, index, total, count)
  if total == 1 then
    return "Found "
      .. tostring(count)
      .. " occurrences of the text in "
      .. tostring(path)
      .. ". The text must be unique. Please provide more context to make it unique."
  end
  return "Found "
    .. tostring(count)
    .. " occurrences of edits["
    .. tostring(index)
    .. "] in "
    .. tostring(path)
    .. ". Each oldText must be unique. Please provide more context to make it unique."
end

local function empty_old_text_error(path, index, total)
  if total == 1 then
    return "oldText must not be empty in " .. tostring(path) .. "."
  end
  return "edits[" .. tostring(index) .. "].oldText must not be empty in " .. tostring(path) .. "."
end

local function no_change_error(path, total)
  if total == 1 then
    return "No changes made to "
      .. tostring(path)
      .. ". The replacement produced identical content."
  end
  return "No changes made to " .. tostring(path) .. ". The replacements produced identical content."
end

local function normalize_edits(edits)
  local out = {}
  for i, edit in ipairs(type(edits) == "table" and edits or {}) do
    if type(edit) ~= "table" then
      return nil
    end
    if type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
      return nil
    end
    out[i] = {
      oldText = normalize_to_lf(edit.oldText),
      newText = normalize_to_lf(edit.newText),
    }
  end
  return out
end

function M.edits_from_input(input)
  input = type(input) == "table" and input or {}
  if type(input.edits) == "table" and #input.edits > 0 then
    return normalize_edits(input.edits)
  end
  if type(input.oldText) == "string" and type(input.newText) == "string" then
    return normalize_edits({ { oldText = input.oldText, newText = input.newText } })
  end
  return nil
end

function M.apply_edits_to_normalized_content(normalized_content, edits, path)
  local normalized_edits = normalize_edits(edits)
  if not normalized_edits or #normalized_edits == 0 then
    return nil, "missing edits"
  end

  for i, edit in ipairs(normalized_edits) do
    if edit.oldText == "" then
      return nil, empty_old_text_error(path, i - 1, #normalized_edits)
    end
  end

  local matched = {}
  for i, edit in ipairs(normalized_edits) do
    local count = count_occurrences(normalized_content, edit.oldText)
    if count == 0 then
      return nil, not_found_error(path, i - 1, #normalized_edits)
    end
    if count > 1 then
      return nil, duplicate_error(path, i - 1, #normalized_edits, count)
    end
    local start_index, end_index = normalized_content:find(edit.oldText, 1, true)
    matched[#matched + 1] = {
      edit_index = i - 1,
      start_index = start_index,
      match_length = end_index - start_index + 1,
      new_text = edit.newText,
    }
  end

  table.sort(matched, function(a, b)
    return a.start_index < b.start_index
  end)
  for i = 2, #matched do
    local previous = matched[i - 1]
    local current = matched[i]
    if previous.start_index + previous.match_length > current.start_index then
      return nil,
        "edits["
          .. tostring(previous.edit_index)
          .. "] and edits["
          .. tostring(current.edit_index)
          .. "] overlap in "
          .. tostring(path)
          .. ". Merge them into one edit or target disjoint regions."
    end
  end

  local new_content = normalized_content
  for i = #matched, 1, -1 do
    local edit = matched[i]
    new_content = new_content:sub(1, edit.start_index - 1)
      .. edit.new_text
      .. new_content:sub(edit.start_index + edit.match_length)
  end

  if normalized_content == new_content then
    return nil, no_change_error(path, #normalized_edits)
  end
  return {
    baseContent = normalized_content,
    newContent = new_content,
    matches = matched,
  }
end

function M.apply_edits_to_text(raw_content, edits, path)
  local bom, content = strip_bom(raw_content or "")
  local file_ending = detect_line_ending(content)
  local normalized, raw_start, raw_end = normalize_with_raw_map(content)
  local applied, err = M.apply_edits_to_normalized_content(normalized, edits, path)
  if not applied then
    return nil, err
  end
  local output = content
  for i = #(applied.matches or {}), 1, -1 do
    local match = applied.matches[i]
    local first = raw_start[match.start_index] or (#content + 1)
    local last = raw_end[match.start_index + match.match_length - 1] or (first - 1)
    local original = content:sub(first, last)
    local replacement_ending = original:find("[\r\n]") and detect_line_ending(original)
      or file_ending
    local replacement = restore_line_endings(match.new_text, replacement_ending)
    output = output:sub(1, first - 1) .. replacement .. output:sub(last + 1)
  end
  applied.output = bom .. output
  return applied
end

local function lcs_ops(old_lines, new_lines)
  local old_count, new_count = #old_lines, #new_lines
  if old_count * new_count > MAX_LCS_CELLS then
    return nil
  end
  local dp = {}
  for i = 0, old_count do
    dp[i] = {}
    dp[i][new_count + 1] = 0
  end
  dp[old_count + 1] = {}
  for j = 0, new_count + 1 do
    dp[old_count + 1][j] = 0
  end
  for i = old_count, 1, -1 do
    for j = new_count, 1, -1 do
      if old_lines[i] == new_lines[j] then
        dp[i][j] = 1 + dp[i + 1][j + 1]
      else
        dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
      end
    end
  end

  local ops = {}
  local i, j = 1, 1
  while i <= old_count and j <= new_count do
    if old_lines[i] == new_lines[j] then
      ops[#ops + 1] = { tag = "=", line = old_lines[i] }
      i = i + 1
      j = j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then
      ops[#ops + 1] = { tag = "-", line = old_lines[i] }
      i = i + 1
    else
      ops[#ops + 1] = { tag = "+", line = new_lines[j] }
      j = j + 1
    end
  end
  while i <= old_count do
    ops[#ops + 1] = { tag = "-", line = old_lines[i] }
    i = i + 1
  end
  while j <= new_count do
    ops[#ops + 1] = { tag = "+", line = new_lines[j] }
    j = j + 1
  end
  return ops
end

local function simple_ops(old_lines, new_lines)
  local prefix = 0
  local limit = math.min(#old_lines, #new_lines)
  while prefix < limit and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end

  local suffix = 0
  while
    suffix < limit - prefix and old_lines[#old_lines - suffix] == new_lines[#new_lines - suffix]
  do
    suffix = suffix + 1
  end

  local ops = {}
  for i = 1, prefix do
    ops[#ops + 1] = { tag = "=", line = old_lines[i] }
  end
  for i = prefix + 1, #old_lines - suffix do
    ops[#ops + 1] = { tag = "-", line = old_lines[i] }
  end
  for i = prefix + 1, #new_lines - suffix do
    ops[#ops + 1] = { tag = "+", line = new_lines[i] }
  end
  for i = #old_lines - suffix + 1, #old_lines do
    ops[#ops + 1] = { tag = "=", line = old_lines[i] }
  end
  return ops
end

local function annotate_ops(ops)
  local annotated = {}
  local old_line_num = 1
  local new_line_num = 1
  local first_changed_line = nil

  for _, op in ipairs(ops) do
    local item = { tag = op.tag, line = op.line }
    if op.tag == "+" then
      item.old_line_num = old_line_num
      item.new_line_num = new_line_num
      if first_changed_line == nil then
        first_changed_line = new_line_num
      end
      new_line_num = new_line_num + 1
    elseif op.tag == "-" then
      item.old_line_num = old_line_num
      item.new_line_num = new_line_num
      if first_changed_line == nil then
        first_changed_line = new_line_num
      end
      old_line_num = old_line_num + 1
    else
      item.old_line_num = old_line_num
      item.new_line_num = new_line_num
      old_line_num = old_line_num + 1
      new_line_num = new_line_num + 1
    end
    annotated[#annotated + 1] = item
  end

  return annotated, first_changed_line
end

local function hunk_range(start_line, count)
  if count == 1 then
    return tostring(start_line)
  end
  return tostring(start_line) .. "," .. tostring(count)
end

local function hunk_bounds(ops, start_idx, end_idx)
  local old_count = 0
  local new_count = 0
  local old_start = nil
  local new_start = nil

  for i = start_idx, end_idx do
    local op = ops[i]
    if op.tag ~= "+" then
      old_count = old_count + 1
      if old_start == nil then
        old_start = op.old_line_num
      end
    end
    if op.tag ~= "-" then
      new_count = new_count + 1
      if new_start == nil then
        new_start = op.new_line_num
      end
    end
  end

  if old_start == nil then
    old_start = math.max(0, ops[start_idx].old_line_num - 1)
  end
  if new_start == nil then
    new_start = math.max(0, ops[start_idx].new_line_num - 1)
  end

  return old_start, old_count, new_start, new_count
end

local function collect_change_indices(ops)
  local changes = {}
  for i, op in ipairs(ops) do
    if op.tag ~= "=" then
      changes[#changes + 1] = i
    end
  end
  return changes
end

local function emit_hunk(output, ops, start_idx, end_idx)
  local old_start, old_count, new_start, new_count = hunk_bounds(ops, start_idx, end_idx)
  output[#output + 1] = "@@ -"
    .. hunk_range(old_start, old_count)
    .. " +"
    .. hunk_range(new_start, new_count)
    .. " @@"

  for i = start_idx, end_idx do
    local op = ops[i]
    if op.tag == "+" then
      output[#output + 1] = "+" .. op.line
    elseif op.tag == "-" then
      output[#output + 1] = "-" .. op.line
    else
      output[#output + 1] = " " .. op.line
    end
  end
end

function M.generate_diff_string(old_content, new_content, context_lines)
  context_lines = tonumber(context_lines) or DEFAULT_CONTEXT_LINES
  local old_lines = split_lines(old_content or "")
  local new_lines = split_lines(new_content or "")
  local raw_ops = lcs_ops(old_lines, new_lines) or simple_ops(old_lines, new_lines)
  local ops, first_changed_line = annotate_ops(raw_ops)
  local changes = collect_change_indices(ops)
  local output = {}

  local change_index = 1
  local previous_hunk_end = 0
  while change_index <= #changes do
    local first_change = changes[change_index]
    local last_change = first_change
    while
      change_index < #changes
      and changes[change_index + 1] - last_change <= (context_lines * 2 + 1)
    do
      change_index = change_index + 1
      last_change = changes[change_index]
    end

    local hunk_start = math.max(previous_hunk_end + 1, first_change - context_lines)
    local hunk_end = math.min(#ops, last_change + context_lines)
    emit_hunk(output, ops, hunk_start, hunk_end)
    previous_hunk_end = hunk_end
    change_index = change_index + 1
  end

  return {
    diff = table.concat(output, "\n"),
    firstChangedLine = first_changed_line,
  }
end

function M.preview_edits(raw_content, edits, path)
  local applied, err = M.apply_edits_to_text(raw_content, edits, path)
  if not applied then
    return nil, err
  end
  local generated = M.generate_diff_string(applied.baseContent, applied.newContent)
  generated.baseContent = applied.baseContent
  generated.newContent = applied.newContent
  generated.output = applied.output
  return generated
end

function M.colored_diff(before_text, after_text)
  local generated = M.generate_diff_string(before_text or "", after_text or "")
  if generated.diff == "" then
    return ansi.dim("  no visible diff")
  end
  local renderer = require("psi.tui_components.diff")
  return renderer.render_diff(generated.diff)
end

function M.preview_output(text)
  local lines = split_lines(text or "")
  if #lines <= 20 then
    return table.concat(lines, "\n")
  end
  local out = prelude.take(lines, 20)
  out[#out + 1] = ansi.dim("...")
  return table.concat(out, "\n")
end

return M
