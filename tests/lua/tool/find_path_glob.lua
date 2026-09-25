--[==[psi-test
expect = "true|true|true"
]==]
local root = TMP .. "/find-path-glob"
psi.mkdir_p(root .. "/src/nested")
psi.file_write(root .. "/src/nested/example.spec.lua", "")
local result = require("psi.tools").dispatch("find", {
  pattern = "src/**/*.spec.lua", path = root,
})
local output = result.extras.output or ""
return tostring(result.ok) .. "|"
  .. tostring(output:find("src/nested/example.spec.lua", 1, true) ~= nil) .. "|"
  .. tostring(output:find(root, 1, true) == nil)
