--[==[psi-test
expect = "true|No matches found"
files = [
  { path = "empty-search.txt", text = "haystack\n" },
]
]==]
local result = require("psi.tools").dispatch("grep", {
  pattern = "needle", path = TMP .. "/empty-search.txt",
})
return tostring(result.ok) .. "|" .. tostring(result.extras.output)
