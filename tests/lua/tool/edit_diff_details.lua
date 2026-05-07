--[==[psi-test
expect = "true|true|true|true|alpha delta\nomega"
files = [
  { path = "edit.txt", text = "alpha beta\nomega" },
]
]==]
local path = TMP .. "/edit.txt"
local tools = require("psi.tools")

local result = tools.dispatch("edit", {
  path = path,
  oldText = "alpha beta",
  newText = "alpha delta",
})

return table.concat({
  tostring(result.ok),
  tostring(result:get("diff"):find("-1 alpha beta", 1, true) ~= nil),
  tostring(result:get("diff"):find("+1 alpha delta", 1, true) ~= nil),
  tostring(result:get("firstChangedLine") == 1),
  psi.read_file(path),
}, "|")
