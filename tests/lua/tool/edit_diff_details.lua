--[==[psi-test
# Edit tool emits a unified-diff `diff` field with `@@` hunk header,
# `-`/`+` body lines, and `--- a/...` / `+++ b/...` file headers so the
# payload round-trips through `patch -p1`.
expect = "true|true|true|true|true|true|true|alpha delta\nomega"
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

local d = result:get("diff")
return table.concat({
  tostring(result.ok),
  tostring(d:find("@@ %-1,%d+ %+1,%d+ @@") ~= nil),
  tostring(d:find("-alpha beta", 1, true) ~= nil),
  tostring(d:find("+alpha delta", 1, true) ~= nil),
  tostring(d:find("--- a/", 1, true) ~= nil),
  tostring(d:find("+++ b/", 1, true) ~= nil),
  tostring(result:get("firstChangedLine") == 1),
  psi.read_file(path),
}, "|")
