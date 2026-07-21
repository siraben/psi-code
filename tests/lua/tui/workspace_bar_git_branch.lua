--[==[psi-test
cwd = "project"
expect = "true|true|24|true"
[[files]]
path = ".git/HEAD"
text = "ref: refs/heads/feature/metadata\n"
[[files]]
path = ".git/config"
text = "[remote \"origin\"]\n  url = http://forge.example/owner/repo.git\n"
]==]
local tui = require("psi.tui_status")
local text = require("psi.tui_text")
local saved = psi.runtime_info
psi.runtime_info = function()
  return { ["git-commit"] = "abc1234" }
end
local full = text.strip_ansi(tui.workspace_bar(psi.cwd()))
local narrow = tui.compose_bar(tui.workspace_bar_for_width(psi.cwd(), 24), 24)
psi.runtime_info = saved
return table.concat({
  tostring(full:find("branch feature/metadata", 1, true) ~= nil),
  tostring(full:find("build abc1234", 1, true) ~= nil),
  tostring(text.visible_width(narrow)),
  tostring(text.strip_ansi(narrow):find("cwd", 1, true) ~= nil),
}, "|")
