--[==[psi-test
expect = "true|true|a.md,b.lua|true"
]==]
local dir = TMP .. "/portable-fs/a/b"
local ok = psi.mkdir_p(dir)
psi.file_write(dir .. "/b.lua", "")
psi.file_write(dir .. "/a.md", "")
local entries = psi.list_dir(dir)
table.sort(entries)
return tostring(ok) .. "|" .. tostring(psi.file_exists(dir)) .. "|"
  .. table.concat(entries, ",") .. "|"
  .. tostring(psi.mkdir_parent(dir .. "/c/d.txt"))
