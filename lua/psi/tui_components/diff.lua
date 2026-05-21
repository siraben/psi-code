-- Unified-diff renderer for tool execution components.
--
-- Consumes the output of psi.diff.generate_diff_string (unified diff
-- format: optional `--- a/` / `+++ b/` file headers, one or more
-- `@@ -X,Y +A,B @@` hunk headers, then body lines prefixed with
-- ' ' / '-' / '+'). Colours each line according to its role and
-- pairs single removed + single added lines for intra-line inverse
-- highlighting on the changed substring.

local ansi = require("psi.ansi")

local M = {}

local FG_CONTEXT = "38;5;242"
local FG_ADDED = "32"
local FG_REMOVED = "31"
local FG_HUNK = "36" -- cyan, like `git diff`
local FG_FILE_HEADER = "1;36" -- bold cyan

local function fg(code, text)
  return ansi.color(code, text or "")
end

local function replace_tabs(text)
  return (text or ""):gsub("\t", "   ")
end

-- Classify a single diff line. Returns one of:
--   { kind = "hunk",   text = "@@ ... @@" }
--   { kind = "file",   text = "--- a/..." or "+++ b/..." }
--   { kind = "added",  content = "..." }
--   { kind = "removed", content = "..." }
--   { kind = "context", content = "..." }
--   { kind = "raw",    text = original line (unrecognised) }
local function classify_line(line)
  line = tostring(line or "")
  if line:sub(1, 2) == "@@" then
    return { kind = "hunk", text = line }
  end
  if line:sub(1, 4) == "--- " or line:sub(1, 4) == "+++ " then
    return { kind = "file", text = line }
  end
  local prefix = line:sub(1, 1)
  if prefix == "+" then
    return { kind = "added", content = line:sub(2) }
  elseif prefix == "-" then
    return { kind = "removed", content = line:sub(2) }
  elseif prefix == " " then
    return { kind = "context", content = line:sub(2) }
  end
  -- Empty line inside a hunk body counts as an empty context line;
  -- unified diff guarantees a sign byte, but be lenient.
  if line == "" then
    return { kind = "context", content = "" }
  end
  return { kind = "raw", text = line }
end

local function utf8_units(value)
  local units = {}
  local i = 1
  value = tostring(value or "")
  while i <= #value do
    local byte = value:byte(i)
    local len = 1
    if byte and byte >= 0xf0 then
      len = 4
    elseif byte and byte >= 0xe0 then
      len = 3
    elseif byte and byte >= 0xc2 then
      len = 2
    end
    if i + len - 1 > #value then
      len = 1
    end
    units[#units + 1] = value:sub(i, i + len - 1)
    i = i + len
  end
  return units
end

local function concat_units(units, first, last)
  if first > last then
    return ""
  end
  local out = {}
  for i = first, last do
    out[#out + 1] = units[i]
  end
  return table.concat(out)
end

local function common_prefix_units(a, b)
  local limit = math.min(#a, #b)
  local i = 1
  while i <= limit and a[i] == b[i] do
    i = i + 1
  end
  return i - 1
end

local function common_suffix_units(a, b, prefix_len)
  local limit = math.min(#a, #b) - prefix_len
  local count = 0
  while count < limit and a[#a - count] == b[#b - count] do
    count = count + 1
  end
  return count
end

-- Highlight the changed substring of a single removed/added pair via
-- ANSI inverse. Leading whitespace stays unhighlighted so indentation
-- doesn't get noisy.
local function render_intra_line_diff(old_content, new_content)
  local old_leading = old_content:match("^%s*") or ""
  local new_leading = new_content:match("^%s*") or ""
  local old_tail = old_content:sub(#old_leading + 1)
  local new_tail = new_content:sub(#new_leading + 1)
  local old_units = utf8_units(old_tail)
  local new_units = utf8_units(new_tail)
  local prefix = common_prefix_units(old_units, new_units)
  local suffix = common_suffix_units(old_units, new_units, prefix)
  local old_changed = concat_units(old_units, prefix + 1, #old_units - suffix)
  local new_changed = concat_units(new_units, prefix + 1, #new_units - suffix)
  local old_line = old_leading .. concat_units(old_units, 1, prefix)
  local new_line = new_leading .. concat_units(new_units, 1, prefix)
  if old_changed ~= "" then
    old_line = old_line .. ansi.inverse(old_changed)
  end
  if new_changed ~= "" then
    new_line = new_line .. ansi.inverse(new_changed)
  end
  if suffix > 0 then
    old_line = old_line .. concat_units(old_units, #old_units - suffix + 1, #old_units)
    new_line = new_line .. concat_units(new_units, #new_units - suffix + 1, #new_units)
  end
  return old_line, new_line
end

function M.render_diff(diff_text)
  local text = tostring(diff_text or "")
  if text == "" then
    return ""
  end

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local result = {}
  local i = 1
  while i <= #lines do
    local entry = classify_line(lines[i])

    if entry.kind == "file" then
      result[#result + 1] = fg(FG_FILE_HEADER, entry.text)
      i = i + 1
    elseif entry.kind == "hunk" then
      result[#result + 1] = fg(FG_HUNK, entry.text)
      i = i + 1
    elseif entry.kind == "removed" then
      -- Collect a run of consecutive removed lines, then a run of
      -- consecutive added lines. If exactly one of each, render with
      -- intra-line inverse highlights; otherwise render them as-is.
      local removed = {}
      while i <= #lines do
        local e = classify_line(lines[i])
        if e.kind ~= "removed" then
          break
        end
        removed[#removed + 1] = e
        i = i + 1
      end
      local added = {}
      while i <= #lines do
        local e = classify_line(lines[i])
        if e.kind ~= "added" then
          break
        end
        added[#added + 1] = e
        i = i + 1
      end

      if #removed == 1 and #added == 1 then
        local removed_line, added_line = render_intra_line_diff(
          replace_tabs(removed[1].content),
          replace_tabs(added[1].content)
        )
        result[#result + 1] = fg(FG_REMOVED, "-" .. removed_line)
        result[#result + 1] = fg(FG_ADDED, "+" .. added_line)
      else
        for _, e in ipairs(removed) do
          result[#result + 1] = fg(FG_REMOVED, "-" .. replace_tabs(e.content))
        end
        for _, e in ipairs(added) do
          result[#result + 1] = fg(FG_ADDED, "+" .. replace_tabs(e.content))
        end
      end
    elseif entry.kind == "added" then
      result[#result + 1] = fg(FG_ADDED, "+" .. replace_tabs(entry.content))
      i = i + 1
    elseif entry.kind == "context" then
      result[#result + 1] = fg(FG_CONTEXT, " " .. replace_tabs(entry.content))
      i = i + 1
    else
      result[#result + 1] = fg(FG_CONTEXT, entry.text or "")
      i = i + 1
    end
  end
  return table.concat(result, "\n")
end

return M
