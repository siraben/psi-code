--[==[psi-test
expect = "true|true|true|false"
files = [
  { path = "context.txt", text = "before\nneedle one\nafter\nneedle two\n" },
]
]==]
local result = require("psi.tools").dispatch("grep", {
  pattern = "needle", path = TMP .. "/context.txt", context = 1, limit = 1,
})
local output = result.extras.output or ""
return tostring(result.ok) .. "|"
  .. tostring(output:find("before", 1, true) ~= nil) .. "|"
  .. tostring(output:find("needle one", 1, true) ~= nil) .. "|"
  .. tostring(output:find("needle two", 1, true) ~= nil)
