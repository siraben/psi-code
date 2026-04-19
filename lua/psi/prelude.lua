-- psi.prelude: small string/table/path helpers used across the runtime.

local M = {}

-- ---------- strings ----------

function M.trim(text)
  return (text:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

function M.starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

function M.split(text, sep)
  local out, start = {}, 1
  local i = text:find(sep, start, true)
  while i do
    out[#out + 1] = text:sub(start, i - 1)
    start = i + #sep
    i = text:find(sep, start, true)
  end
  out[#out + 1] = text:sub(start)
  return out
end

function M.split_lines(text)
  return M.split(text, "\n")
end

function M.join(pieces, sep)
  return table.concat(pieces, sep)
end

function M.replace_first(text, old, new)
  local i, j = text:find(old, 1, true)
  if not i then return nil end
  return text:sub(1, i - 1) .. new .. text:sub(j + 1)
end

-- ---------- sequences (1-indexed Lua tables) ----------

function M.length(xs)
  return #xs
end

function M.take(xs, n)
  if n <= 0 then return {} end
  local out = {}
  for i = 1, math.min(n, #xs) do out[#out + 1] = xs[i] end
  return out
end

function M.drop(xs, n)
  if n <= 0 then return xs end
  local out = {}
  for i = n + 1, #xs do out[#out + 1] = xs[i] end
  return out
end

function M.take_right(xs, n)
  local len = #xs
  if n <= 0 then return {} end
  local out = {}
  local start = math.max(1, len - n + 1)
  for i = start, len do out[#out + 1] = xs[i] end
  return out
end

function M.reverse(xs)
  local out = {}
  for i = #xs, 1, -1 do out[#out + 1] = xs[i] end
  return out
end

function M.map(xs, fn)
  local out = {}
  for i, v in ipairs(xs) do out[i] = fn(v) end
  return out
end

function M.filter(xs, pred)
  local out = {}
  for _, v in ipairs(xs) do
    if pred(v) then out[#out + 1] = v end
  end
  return out
end

function M.each(xs, fn)
  for _, v in ipairs(xs) do fn(v) end
end

-- ---------- paths ----------

-- Tag a table as a JSON array so it serializes as `[]` even when empty.
function M.as_array(t)
  local existing = getmetatable(t)
  if existing and existing.__jsontype == "array" then return t end
  return setmetatable(t or {}, {__jsontype = "array"})
end

function M.path_join(base, name)
  if base == "/" then return "/" .. name end
  if base == "." then return name end
  return base .. "/" .. name
end

return M
