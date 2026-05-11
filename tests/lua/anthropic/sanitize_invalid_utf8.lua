--[==[psi-test
expect = "ok"
]==]
-- Anthropic rejects any body that isn't well-formed UTF-8 with
-- HTTP 400 "str is not valid UTF-8: surrogates not allowed". The
-- prelude.sanitize_surrogates helper used to only strip the CESU-8
-- pattern for lone UTF-16 surrogates (ED [A0-BF] [80-BF]) and left
-- other invalid byte sequences in the request body, e.g. stray
-- continuation bytes from a tool that streamed binary output (a gdb
-- session printing raw bytes via printf %c is the case that caught
-- this in the wild). It now strips any byte that isn't part of a
-- valid UTF-8 scalar value.

local prelude = require("psi.prelude")
local s = prelude.sanitize_surrogates

local cases = {
  -- valid input must round-trip unchanged
  { "ascii",                   "hello",                              "hello" },
  { "empty",                   "",                                   "" },
  { "valid 2-byte (\xC3\xA9)", "caf\xC3\xA9",                        "caf\xC3\xA9" },
  { "valid 3-byte (\xE6\xBC\xA2)", "\xE6\xBC\xA2\xE5\xAD\x97",       "\xE6\xBC\xA2\xE5\xAD\x97" },
  { "valid 4-byte (U+1F648)",  "a\xF0\x9F\x99\x88b",                 "a\xF0\x9F\x99\x88b" },
  -- lone UTF-16 surrogates (the original sanitize_surrogates case)
  { "lone high surrogate",     "a\xED\xA0\xBDb",                     "ab" },
  { "lone low surrogate",      "a\xED\xB8\x80b",                     "ab" },
  -- new coverage: stray bytes that the old impl let through
  { "stray continuation 0x88", "a\x88b",                             "ab" },
  { "truncated 2-byte lead",   "a\xC2b",                             "ab" },
  { "truncated 3-byte lead",   "a\xE6\xBCb",                         "ab" },
  { "overlong 2-byte NUL",     "a\xC0\x80b",                         "ab" },
  { "overlong 3-byte",         "a\xE0\x80\x80b",                     "ab" },
  { "overlong 4-byte",         "a\xF0\x80\x80\x80b",                 "ab" },
  { "F4 90 (>U+10FFFF)",       "a\xF4\x90\x80\x80b",                 "ab" },
  { "invalid lead 0xFF",       "a\xFFb",                             "ab" },
  -- realistic reproducer: gdb printing %c on a binary file
  { "gdb mixed binary output", "x=0x88 (\x88)\nx=0x84 (\x84)\n",    "x=0x88 ()\nx=0x84 ()\n" },
}

local fails = {}
for _, c in ipairs(cases) do
  local name, input, want = c[1], c[2], c[3]
  local got = s(input)
  if got ~= want then
    fails[#fails + 1] = string.format("%s: got %q want %q", name, got, want)
  end
end

if #fails == 0 then
  return "ok"
end
return table.concat(fails, "; ")
