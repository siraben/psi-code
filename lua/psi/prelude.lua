-- psi.prelude: small string/table/path helpers used across the runtime.

local M = {}
local table_create = rawget(table, "create")
local ARRAY_METATABLE = { __jsontype = "array" }

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

function M.hash_hex(text)
  text = tostring(text or "")
  local h1 = 5381
  local h2 = 2166136261
  for i = 1, #text do
    local b = text:byte(i) or 0
    h1 = ((h1 * 33) + b) % 4294967296
    h2 = ((h2 * 131) + b) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
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

local REPLACEMENT = "\239\191\189"

-- Strip any byte sequence from a string that is not well-formed UTF-8.
--
-- Anthropic's API rejects request bodies that contain malformed UTF-8
-- with HTTP 400 "str is not valid UTF-8: surrogates not allowed" (the
-- error message is misleading — the same 400 fires for *any* invalid
-- byte, not just CESU-8-encoded lone surrogates). Bad bytes leak in
-- whenever a tool echoes binary output: e.g. a gdb session printing
-- raw bytes via printf %c, a read of a non-UTF-8 file, or a process
-- streaming partial multi-byte sequences. We strip them at the
-- provider boundary so the on-wire body always validates.
--
-- This supersedes the earlier sanitize_surrogates which only handled
-- the ED [A0-BF] [80-BF] CESU-8 pattern; lone continuation bytes
-- (0x80-0xBF without a lead byte), overlong sequences, and 4-byte
-- leads with truncated trailers all caused the same 400 and slipped
-- through. The function keeps its old name for API compatibility.
--
-- Stripping rules match the Unicode Standard (table 3-7): each byte
-- that cannot start or continue a valid UTF-8 scalar value is
-- silently removed. Properly-encoded text (ASCII, emoji, CJK, ZWJ
-- sequences) passes through unchanged.
local function utf8_seq_len(c)
  if c < 0x80 then
    return 1
  elseif c < 0xC2 then
    return 0 -- 0x80..0xBF stray continuation, 0xC0/0xC1 overlong
  elseif c < 0xE0 then
    return 2
  elseif c < 0xF0 then
    return 3
  elseif c < 0xF5 then
    return 4
  end
  return 0 -- 0xF5..0xFF never valid
end

-- Validate the trailer bytes for a 2/3/4-byte UTF-8 sequence starting
-- at index `i` with lead byte `c`. Returns true if all trailers exist
-- and the encoded scalar value is in-range (no overlongs, no
-- surrogates U+D800..DFFF, no code points > U+10FFFF).
local function utf8_seq_ok(s, i, c, n)
  local b1 = string.byte(s, i + 1)
  if b1 == nil or b1 < 0x80 or b1 > 0xBF then
    return false
  end
  if n == 2 then
    return true
  end
  -- Range-restrict the second byte for the boundary leads:
  --   E0    -> A0..BF (reject overlong)
  --   ED    -> 80..9F (reject surrogate halves)
  --   F0    -> 90..BF (reject overlong)
  --   F4    -> 80..8F (reject > U+10FFFF)
  if c == 0xE0 and b1 < 0xA0 then
    return false
  elseif c == 0xED and b1 > 0x9F then
    return false
  elseif c == 0xF0 and b1 < 0x90 then
    return false
  elseif c == 0xF4 and b1 > 0x8F then
    return false
  end
  local b2 = string.byte(s, i + 2)
  if b2 == nil or b2 < 0x80 or b2 > 0xBF then
    return false
  end
  if n == 3 then
    return true
  end
  local b3 = string.byte(s, i + 3)
  return b3 ~= nil and b3 >= 0x80 and b3 <= 0xBF
end

-- Shared span scanner for sanitize_surrogates / decode_utf8_lossy: copies
-- clean spans in bulk; valid input returns the ORIGINAL string with no
-- allocation. replacement == nil drops invalid bytes, U+FFFD substitutes.
local function rewrite_invalid_utf8(text, replacement)
  local out = nil
  local copied = 0 -- everything up to and including this index is handled
  local n = #text
  local i = 1
  while true do
    local j = text:find("[\x80-\xFF]", i)
    if not j then
      break
    end
    local c = string.byte(text, j)
    local seq = utf8_seq_len(c)
    if seq > 1 and utf8_seq_ok(text, j, c, seq) then
      i = j + seq
    else
      if out == nil then
        out = {}
      end
      if j > copied + 1 then
        out[#out + 1] = text:sub(copied + 1, j - 1)
      end
      if replacement then
        out[#out + 1] = replacement
      end
      copied = j
      i = j + 1
    end
  end
  if out == nil then
    return text
  end
  if copied < n then
    out[#out + 1] = text:sub(copied + 1)
  end
  return table.concat(out)
end

function M.sanitize_surrogates(text)
  if type(text) ~= "string" or text == "" then
    return text or ""
  end
  return rewrite_invalid_utf8(text, nil)
end

-- Decode arbitrary bytes to model-visible text the way pi-mono's
-- Buffer.toString/TextDecoder paths do: valid UTF-8 survives and
-- malformed bytes become U+FFFD instead of remaining raw bytes in the
-- transcript. Provider-specific request builders still call
-- sanitize_surrogates as a final wire guard.
function M.decode_utf8_lossy(text)
  if type(text) ~= "string" or text == "" then
    return text or ""
  end
  return rewrite_invalid_utf8(text, REPLACEMENT)
end

-- Copy-on-write recursive decode returning (decoded, changed): clean
-- values return the ORIGINAL unchanged; only tables on the path to a
-- rewrite are re-allocated. Input and result are immutable snapshots.
local function decode_value(value, seen)
  if type(value) == "string" then
    local decoded = M.decode_utf8_lossy(value)
    return decoded, decoded ~= value
  elseif type(value) ~= "table" then
    return value, false
  end
  if seen[value] then
    -- Cycle: resolve to the original table, matching the pre-COW
    -- behavior of returning `value` for already-seen tables.
    return value, false
  end
  seen[value] = true
  local out = nil
  for k, v in pairs(value) do
    local decoded, changed = decode_value(v, seen)
    if out ~= nil then
      out[k] = decoded
    elseif changed then
      -- First rewritten child: shallow-copy; keys visited earlier were
      -- unchanged, so their raw copies are already correct.
      out = {}
      for k2, v2 in pairs(value) do
        out[k2] = v2
      end
      out[k] = decoded
    end
  end
  if out == nil then
    return value, false
  end
  local mt = getmetatable(value)
  if mt then
    setmetatable(out, mt)
  end
  return out, true
end

function M.decode_model_value(value)
  return (decode_value(value, {}))
end

-- ---------- paths ----------

-- Tag a table as a JSON array so it serializes as `[]` even when empty.
function M.as_array(t)
  local existing = getmetatable(t)
  if existing and existing.__jsontype == "array" then
    return t
  end
  return setmetatable(t or {}, ARRAY_METATABLE)
end

function M.resolve_env(explicit, env_var, default)
  if explicit and explicit ~= "" then
    return explicit
  end
  local env = os.getenv(env_var)
  if env and env ~= "" then
    return env
  end
  return default
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
