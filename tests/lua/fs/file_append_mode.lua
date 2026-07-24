--[==[psi-test
expect = "420|384"
]==]
-- A mode argument applies only to files the append creates; a
-- pre-existing file keeps its permissions.
local existing = TMP .. "/append-existing.txt"
assert(psi.file_write(existing, "a"))
assert(psi.file_chmod(existing, 420)) -- 0644
assert(psi.file_append(existing, "b", 384))
local created = TMP .. "/append-created.txt"
assert(psi.file_append(created, "x", 384)) -- 0600
return tostring(psi.file_mode(existing)) .. "|" .. tostring(psi.file_mode(created))
