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

-- ---------- Unified-diff hunk emission ----------
--
-- Body lines use the standard unified-diff format: a single-character
-- prefix (' ' / '-' / '+') followed by the verbatim file content.
-- Hunks are introduced by `@@ -old_start,old_count +new_start,new_count @@`.
-- A new hunk starts whenever the gap between two change runs exceeds
-- 2 * context_lines unchanged lines, matching `diff -u` behaviour.

local function op_prefix(tag)
  if tag == "+" then
    return "+"
  elseif tag == "-" then
    return "-"
  end
  return " "
end

local function emit_op(output, op)
  output[#output + 1] = op_prefix(op.tag) .. op.line
end

-- Build the list of hunks. A hunk is a contiguous slice of ops with
-- context_lines of unchanged ops on either side; consecutive change
-- runs that sit within 2 * context_lines of unchanged ops of each
-- other are merged into the same hunk.
local function build_hunks(ops, context_lines)
  local hunks = {}
  local changed_indices = {}
  for i, op in ipairs(ops) do
    if op.tag ~= "=" then
      changed_indices[#changed_indices + 1] = i
    end
  end
  if #changed_indices == 0 then
    return hunks
  end

  local group_start = changed_indices[1]
  local group_end = changed_indices[1]
  for i = 2, #changed_indices do
    local idx = changed_indices[i]
    -- Gap = number of unchanged ops between the previous change and this one.
    if idx - group_end - 1 > context_lines * 2 then
      hunks[#hunks + 1] = { first_change = group_start, last_change = group_end }
      group_start = idx
    end
    group_end = idx
  end
  hunks[#hunks + 1] = { first_change = group_start, last_change = group_end }

  for _, hunk in ipairs(hunks) do
    hunk.start_index = math.max(1, hunk.first_change - context_lines)
    hunk.end_index = math.min(#ops, hunk.last_change + context_lines)
  end
  return hunks
end

-- Walk hunk ops to compute the (old_start, old_count, new_start,
-- new_count) tuple for the `@@` header. Counts are how many old/new
-- lines this hunk covers; starts are 1-based line numbers in each
-- side. Following `diff -u`, an empty side gets start=0.
local function hunk_header_range(ops, hunk)
  local old_count, new_count = 0, 0
  local old_start, new_start
  for i = hunk.start_index, hunk.end_index do
    local op = ops[i]
    if op.tag == "-" or op.tag == "=" then
      if not old_start then
        old_start = op.old_line_num
      end
      old_count = old_count + 1
    end
    if op.tag == "+" or op.tag == "=" then
      if not new_start then
        new_start = op.new_line_num
      end
      new_count = new_count + 1
    end
  end
  return old_start or 0, old_count, new_start or 0, new_count
end

local function emit_unified_diff(output, ops, context_lines)
  local hunks = build_hunks(ops, context_lines)
  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = hunk_header_range(ops, hunk)
    output[#output + 1] = string.format(
      "@@ -%d,%d +%d,%d @@",
      old_start, old_count, new_start, new_count
    )
    for i = hunk.start_index, hunk.end_index do
      emit_op(output, ops[i])
    end
  end
end

-- Generate a unified diff for `old_content` vs `new_content`. Returns
-- a table with `diff` (the patch text) and `firstChangedLine` (the
-- line number in the new file where the first change appears, or nil).
--
-- `opts.path` (optional) emits `--- a/<path>` / `+++ b/<path>` file
-- headers, making the output a self-contained patch parseable by
-- `patch -p1` and `git apply`.
function M.generate_diff_string(old_content, new_content, context_lines, opts)
  if type(context_lines) == "table" and opts == nil then
    opts = context_lines
    context_lines = opts.context_lines
  end
  context_lines = math.max(0, math.floor(tonumber(context_lines) or DEFAULT_CONTEXT_LINES))
  opts = type(opts) == "table" and opts or {}

  local old_lines = split_lines(old_content or "")
  local new_lines = split_lines(new_content or "")
  -- Drop the trailing empty entry produced by split() when the file
  -- ends in a newline. This matches `diff -u`'s notion of how many
  -- "lines" a file has, so hunk counts agree with GNU diff and the
  -- output round-trips through `patch -p1` cleanly. If exactly one
  -- side lacks a trailing newline we preserve that asymmetry so the
  -- resulting hunk surfaces the missing-newline change.
  local old_has_trailing = #old_lines > 0 and old_lines[#old_lines] == ""
  local new_has_trailing = #new_lines > 0 and new_lines[#new_lines] == ""
  if old_has_trailing and new_has_trailing then
    old_lines[#old_lines] = nil
    new_lines[#new_lines] = nil
  end
  local raw_ops = lcs_ops(old_lines, new_lines) or simple_ops(old_lines, new_lines)
  local ops, first_changed_line = annotate_ops(raw_ops)
  local output = {}

  local has_change = false
  for _, op in ipairs(ops) do
    if op.tag ~= "=" then
      has_change = true
      break
    end
  end

  if has_change then
    if type(opts.path) == "string" and opts.path ~= "" then
      -- `git diff` strips the leading slash from absolute paths so the
      -- a/ and b/ prefixes still produce one slash. Match that so the
      -- output is round-trippable through `git apply -p1` or `patch -p1`.
      local header_path = opts.path
      if header_path:sub(1, 1) == "/" then
        header_path = header_path:sub(2)
      end
      output[#output + 1] = "--- a/" .. header_path
      output[#output + 1] = "+++ b/" .. header_path
    end
    emit_unified_diff(output, ops, context_lines)
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
  local generated = M.generate_diff_string(
    applied.baseContent,
    applied.newContent,
    nil,
    { path = path }
  )
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
