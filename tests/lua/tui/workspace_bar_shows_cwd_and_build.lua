--[==[psi-test
expect = "true|true|true"
]==]
local tui = require("psi.tui_status")
local saved = psi.runtime_info
psi.runtime_info = function()
  return { ["git-commit"] = "abc1234" }
end
local line = tui.compose_bar(tui.workspace_bar("/tmp/example-project", 48), 48)
psi.runtime_info = saved
return table.concat({
  tostring(line:find("cwd", 1, true) ~= nil),
  tostring(line:find("/tmp/example-project", 1, true) ~= nil),
  tostring(line:find("abc1234", 1, true) ~= nil),
}, "|")
