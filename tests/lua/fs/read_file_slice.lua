--[[psi-test
expect = "two\nthree|4|3"
files = [
  { path = "slice.txt", text = "one\ntwo\nthree\nfour\n" },
]
]]
local s = psi.read_file_slice(TMP .. "/slice.txt", 1, 2)
return s.text .. '|' .. tostring(s.total_lines) .. '|' .. tostring(s.next_offset)
