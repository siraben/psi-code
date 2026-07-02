-- psi.base64: pure-Lua base64 encoding shared by tools and clipboard.

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Precomputed sextet -> char and 12-bit -> two-char tables: encoding
-- costs two table lookups per 3-byte group.
local CHAR = {}
for i = 0, 63 do
  CHAR[i] = ALPHABET:sub(i + 1, i + 1)
end
local PAIR = {}
for i = 0, 4095 do
  PAIR[i] = CHAR[(i >> 6) & 0x3f] .. CHAR[i & 0x3f]
end

function M.encode(text)
  text = tostring(text or "")
  local byte = string.byte
  local len = #text
  local out = {}
  local n = 0
  local full = len - (len % 3)
  for i = 1, full, 3 do
    local a, b, c = byte(text, i, i + 2)
    local triple = (a << 16) | (b << 8) | c
    out[n + 1] = PAIR[triple >> 12]
    out[n + 2] = PAIR[triple & 0xfff]
    n = n + 2
  end
  local remaining = len - full
  if remaining == 1 then
    local a = byte(text, len)
    out[n + 1] = CHAR[a >> 2] .. CHAR[(a << 4) & 0x3f] .. "=="
  elseif remaining == 2 then
    local a, b = byte(text, len - 1, len)
    local quad = (a << 16) | (b << 8)
    out[n + 1] = PAIR[quad >> 12] .. CHAR[(quad >> 6) & 0x3f] .. "="
  end
  return table.concat(out)
end

return M
