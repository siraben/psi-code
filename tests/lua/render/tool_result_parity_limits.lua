--[==[psi-test
expect = "true|true|true|true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local render = require("psi.render")
local text = require("psi.tui_text")

ansi.enabled = true
ansi.color_enabled = true

local lines = {}
for i = 1, 12 do
  lines[#lines + 1] = "line" .. tostring(i)
end
lines[4] = "line4\27[31m-red"

local bash = render.render_tool_result({
  id = "bash-limit",
  tool = "bash",
  result = { ok = true, status = 0, output = table.concat(lines, "\n") },
})
local bash_plain = text.strip_ansi(bash)

local list_lines = {}
for i = 1, 25 do
  list_lines[#list_lines + 1] = "file" .. tostring(i)
end
local ls = render.render_tool_result({
  id = "ls-limit",
  tool = "ls",
  result = { ok = true, output = table.concat(list_lines, "\n") },
})
local ls_plain = text.strip_ansi(ls)

return table.concat({
  tostring(bash_plain:find("exit 0", 1, true) == nil),
  tostring(bash:find("\27[31m", 1, true) == nil),
  tostring(bash_plain:find("2 earlier lines", 1, true) ~= nil),
  tostring(bash_plain:find("line3", 1, true) ~= nil),
  tostring(bash_plain:find("line2", 1, true) == nil),
  tostring(ls_plain:find("file20", 1, true) ~= nil),
  tostring(ls_plain:find("file21", 1, true) == nil),
  tostring(ls_plain:find("5 more lines, total 25", 1, true) ~= nil),
}, "|")
