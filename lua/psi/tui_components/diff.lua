-- Pi-style diff renderer for tool execution components.

local ansi = require("psi.ansi")

local M = {}

local FG_CONTEXT = "38;5;242"
local FG_ADDED = "32"
local FG_REMOVED = "31"

local function fg(code, text)
  return ansi.color(code, text or "")
end

local function replace_tabs(text)
  return (text or ""):gsub("\t", "   ")
end

local function parse_diff_line(line)
  line = tostring(line or "")
  if line:sub(1, 2) == "@@" or line:sub(1, 3) == "---" or line:sub(1, 3) == "+++" then
    return nil
  end
  local prefix = line:sub(1, 1)
  if prefix ~= "+" and prefix ~= "-" and prefix ~= " " then
    return nil
  end
  local rest = line:sub(2)
  local line_num, content = rest:match("^(%s*%d+)%s(.*)$")
  if not line_num and prefix == " " then
    line_num = rest:match("^(%s*)%.%.%.$")
    if line_num then
      content = "..."
    end
  end
  return {
    prefix = prefix,
    line_num = line_num,
    content = content or rest,
  }
end

local function diff_line(parsed, content)
  if parsed.line_num then
    return parsed.prefix .. parsed.line_num .. " " .. content
  end
  return parsed.prefix .. content
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
  local lines = {}
  local text = tostring(diff_text or "")
  if text == "" then
    return ""
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local result = {}
  local i = 1
  while i <= #lines do
    local parsed = parse_diff_line(lines[i])
    if not parsed then
      result[#result + 1] = fg(FG_CONTEXT, lines[i])
      i = i + 1
    elseif parsed.prefix == "-" then
      local removed = {}
      while i <= #lines do
        local p = parse_diff_line(lines[i])
        if not p or p.prefix ~= "-" then
          break
        end
        removed[#removed + 1] = p
        i = i + 1
      end

      local added = {}
      while i <= #lines do
        local p = parse_diff_line(lines[i])
        if not p or p.prefix ~= "+" then
          break
        end
        added[#added + 1] = p
        i = i + 1
      end

      if #removed == 1 and #added == 1 then
        local removed_line, added_line =
          render_intra_line_diff(replace_tabs(removed[1].content), replace_tabs(added[1].content))
        result[#result + 1] = fg(FG_REMOVED, diff_line(removed[1], removed_line))
        result[#result + 1] = fg(FG_ADDED, diff_line(added[1], added_line))
      else
        for _, line in ipairs(removed) do
          result[#result + 1] = fg(FG_REMOVED, diff_line(line, replace_tabs(line.content)))
        end
        for _, line in ipairs(added) do
          result[#result + 1] = fg(FG_ADDED, diff_line(line, replace_tabs(line.content)))
        end
      end
    elseif parsed.prefix == "+" then
      result[#result + 1] = fg(FG_ADDED, diff_line(parsed, replace_tabs(parsed.content)))
      i = i + 1
    else
      result[#result + 1] = fg(FG_CONTEXT, diff_line(parsed, replace_tabs(parsed.content)))
      i = i + 1
    end
  end
  return table.concat(result, "\n")
end

return M
