--[==[psi-test
expect = "abc|nil"
]==]
local path = TMP .. "/limited.txt"
assert(psi.file_write(path, "abc"))
return tostring(psi.read_file_limited(path, 3)) .. "|" .. tostring(psi.read_file_limited(path, 2))
