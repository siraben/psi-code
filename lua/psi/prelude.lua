-- psi.prelude: small string/table/path helpers used across the runtime.

local M = {}
local table_create = rawget(table, "create")

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
  if not i then
    return nil
  end
  return text:sub(1, i - 1) .. new .. text:sub(j + 1)
end

-- ---------- sequences (1-indexed Lua tables) ----------

function M.array(nseq, nrec)
  if table_create then
    return table_create(nseq or 0, nrec or 0)
  end
  return {}
end

function M.length(xs)
  return #xs
end

function M.take(xs, n)
  if n <= 0 then
    return M.array(0)
  end
  local count = math.min(n, #xs)
  local out = M.array(count)
  table.move(xs, 1, count, 1, out)
  return out
end

function M.drop(xs, n)
  if n <= 0 then
    return xs
  end
  local count = math.max(0, #xs - n)
  local out = M.array(count)
  table.move(xs, n + 1, #xs, 1, out)
  return out
end

function M.take_right(xs, n)
  local len = #xs
  if n <= 0 then
    return M.array(0)
  end
  local count = math.min(n, len)
  local out = M.array(count)
  local start = math.max(1, len - n + 1)
  table.move(xs, start, len, 1, out)
  return out
end

function M.reverse(xs)
  local out = M.array(#xs)
  for i = #xs, 1, -1 do
    out[#out + 1] = xs[i]
  end
  return out
end

function M.map(xs, fn)
  local out = M.array(#xs)
  for i, v in ipairs(xs) do
    out[i] = fn(v)
  end
  return out
end

function M.filter(xs, pred)
  local out = M.array(#xs)
  for _, v in ipairs(xs) do
    if pred(v) then
      out[#out + 1] = v
    end
  end
  return out
end

function M.each(xs, fn)
  for _, v in ipairs(xs) do
    fn(v)
  end
end

-- ---------- ids / timestamps ----------

if not (psi and psi.amiga_bridge) then
  math.randomseed((os.time() * 1000003) + (os.clock() * 1e6))
end

-- Pseudo-UUIDv4: 16 random bytes rendered as 8-4-4-4-12 hex. Not
-- cryptographic; used only to tag session entries.
local uuid_counter = 0
function M.uuid_short()
  if not (psi and psi.amiga_bridge) then
    local t = M.array(32)
    for i = 1, 32 do
      t[i] = string.format("%x", math.random(0, 15))
    end
    return table.concat(t, "", 1, 8)
      .. "-"
      .. table.concat(t, "", 9, 12)
      .. "-"
      .. "4"
      .. table.concat(t, "", 14, 16)
      .. "-"
      .. string.format("%x", (math.random(0, 3) + 8))
      .. table.concat(t, "", 18, 20)
      .. "-"
      .. table.concat(t, "", 21, 32)
  end

  uuid_counter = uuid_counter + 1
  local digits = "0123456789abcdef"
  local n = uuid_counter
  local t = M.array(32)
  for i = 1, 32 do
    n = n + i * 7
    while n >= 16 do
      n = n - 16
    end
    t[i] = digits:sub(n + 1, n + 1)
  end
  local variant = uuid_counter
  while variant >= 4 do
    variant = variant - 4
  end
  return table.concat(t, "", 1, 8)
    .. "-"
    .. table.concat(t, "", 9, 12)
    .. "-"
    .. "4"
    .. table.concat(t, "", 14, 16)
    .. "-"
    .. digits:sub(9 + variant, 9 + variant)
    .. table.concat(t, "", 18, 20)
    .. "-"
    .. table.concat(t, "", 21, 32)
end

function M.iso_timestamp()
  if not (psi and psi.amiga_bridge) then
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
  end
  return "2026-04-25T00:00:00Z"
end

-- ---------- json / eval / io shims ----------

-- Decode JSON text, returning `fallback` on nil/empty input or parse error.
function M.safe_json_decode(text, fallback)
  if not text or text == "" then
    return fallback
  end
  local ok, value = pcall(psi.json_decode, text)
  if not ok then
    return fallback
  end
  return value
end

-- Compile a Lua expression (preferring `return expr` form, falling back to
-- statement form) and evaluate it. Returns (ok, value_or_error).
function M.eval_expression(expression)
  local chunk, err = load("return " .. expression, "=eval", "t")
  if not chunk then
    chunk, err = load(expression, "=eval", "t")
  end
  if not chunk then
    return false, err or "load error"
  end
  return pcall(chunk)
end

-- Read a file if it exists; return its contents or nil.
function M.safe_read(path)
  if path and psi.file_exists(path) then
    return psi.read_file(path)
  end
  return nil
end

-- Strip the UTF-8 encodings of lone UTF-16 surrogate code points
-- (U+D800..U+DFFF) from a string. Ported from pi's sanitizeSurrogates.
--
-- Anthropic's API rejects requests whose bodies contain these byte
-- sequences with 400 "invalid UTF-8"; they can creep in when the model
-- echoes bytes it read from a malformed file via the read tool. Well-
-- formed Unicode (emoji etc.) is untouched.
--
-- Encoding details: a lone surrogate in CESU-8 / invalid-UTF-8 is
-- always the 3-byte sequence ED [A0..BF] [80..BF].
function M.sanitize_surrogates(text)
  if type(text) ~= "string" or text == "" then
    return text or ""
  end
  return (text:gsub("\xED[\xA0-\xBF][\x80-\xBF]", ""))
end

-- ---------- paths ----------

-- Tag a table as a JSON array so it serializes as `[]` even when empty.
function M.as_array(t)
  local existing = getmetatable(t)
  if existing and existing.__jsontype == "array" then
    return t
  end
  return setmetatable(t or {}, { __jsontype = "array" })
end

function M.path_join(base, name)
  if psi and psi.path_join then
    return psi.path_join(base, name)
  end
  if base == "/" then
    return "/" .. name
  end
  if base == "." then
    return name
  end
  return base .. "/" .. name
end

return M
