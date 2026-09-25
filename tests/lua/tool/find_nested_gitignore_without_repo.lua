--[==[psi-test
expect = "true|false|true"
]==]
local root = TMP .. "/find-nested-ignore"
psi.mkdir_p(root .. "/a")
psi.mkdir_p(root .. "/b")
psi.file_write(root .. "/a/.gitignore", "ignored.txt\n")
psi.file_write(root .. "/a/ignored.txt", "")
psi.file_write(root .. "/b/ignored.txt", "")
local result = require("psi.tools").dispatch("find", {
  pattern = "**/*.txt", path = root,
})
local output = result.extras.output or ""
return tostring(result.ok) .. "|"
  .. tostring(output:find("a/ignored.txt", 1, true) ~= nil) .. "|"
  .. tostring(output:find("b/ignored.txt", 1, true) ~= nil)
