--[==[psi-test
expect = "|4|nil|two\nthree|3"
files = [
  { path = "slice.txt", text = "one\ntwo\nthree\nfour\n" },
]
]==]
-- Huge offset/limit must not overflow signed arithmetic: the window
-- compares use subtraction, and next_offset stays nil past EOF.
local huge = psi.read_file_slice(TMP .. "/slice.txt", math.maxinteger - 5, math.maxinteger - 3)
local normal = psi.read_file_slice(TMP .. "/slice.txt", 1, 2)
return huge.text .. "|" .. tostring(huge.total_lines) .. "|" .. tostring(huge.next_offset)
  .. "|" .. normal.text .. "|" .. tostring(normal.next_offset)
