-- psi.diff: simple line-based colored diff rendering.

local prelude = require("psi.prelude")
local ansi = require("psi.ansi")

local M = {}

local function common_prefix_length(xs, ys)
  local n = math.min(#xs, #ys)
  local count = 0
  for i = 1, n do
    if xs[i] == ys[i] then
      count = count + 1
    else
      break
    end
  end
  return count
end

local function common_suffix_length(xs, ys, prefix_count)
  local xlen, ylen = #xs, #ys
  local count = 0
  while count < math.min(xlen, ylen) - prefix_count and xs[xlen - count] == ys[ylen - count] do
    count = count + 1
  end
  return count
end

local function middle_lines(xs, prefix_count, suffix_count)
  local out = {}
  for i = prefix_count + 1, #xs - suffix_count do
    out[#out + 1] = xs[i]
  end
  return out
end

local function limit_lines(lines, max_lines)
  if #lines <= max_lines then
    return lines
  end
  local out = prelude.take(lines, max_lines)
  out[#out + 1] = ansi.dim("...")
  return out
end

local function context_lines(lines, prefix)
  local out = {}
  for _, line in ipairs(lines) do
    out[#out + 1] = prefix .. line
  end
  return out
end

function M.colored_diff(before_text, after_text)
  local before = prelude.split_lines(before_text or "")
  local after = prelude.split_lines(after_text or "")
  local pc = common_prefix_length(before, after)
  local sc = common_suffix_length(before, after, pc)
  local before_middle = middle_lines(before, pc, sc)
  local after_middle = middle_lines(after, pc, sc)

  local before_ctx = prelude.take_right(prelude.take(before, pc), 2)
  local after_trim = prelude.reverse(prelude.take(prelude.reverse(after), sc))
  local after_ctx = prelude.take(after_trim, 2)

  local rendered = {}
  for _, l in ipairs(context_lines(before_ctx, ansi.dim("  "))) do
    rendered[#rendered + 1] = l
  end
  for _, l in ipairs(limit_lines(before_middle, 40)) do
    rendered[#rendered + 1] = ansi.red("- " .. l)
  end
  for _, l in ipairs(limit_lines(after_middle, 40)) do
    rendered[#rendered + 1] = ansi.green("+ " .. l)
  end
  for _, l in ipairs(context_lines(after_ctx, ansi.dim("  "))) do
    rendered[#rendered + 1] = l
  end

  if #rendered == 0 then
    return ansi.dim("  no visible diff")
  end
  return table.concat(rendered, "\n")
end

function M.preview_output(text)
  return table.concat(limit_lines(prelude.split_lines(text), 20), "\n")
end

return M
