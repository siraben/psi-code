--[==[psi-test
expect = "420|384|true"
]==]
local p = TMP .. "/mode.txt"
assert(psi.file_write(p, "x"))
assert(psi.file_chmod(p, 420))
local initial = psi.file_mode(p)
assert(psi.file_chmod(p, 384))
return tostring(initial) .. "|" .. tostring(psi.file_mode(p)) .. "|"
  .. tostring(psi.file_mode(TMP .. "/missing") == nil)
