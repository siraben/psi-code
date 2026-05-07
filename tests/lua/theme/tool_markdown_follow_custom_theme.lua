--[==[psi-test
expect = "true|false|true|false"
]==]
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local markdown = require("psi.markdown")
local tool = require("psi.tui_components.tool_execution")

ansi.enabled = true
ansi.color_enabled = true
theme.use({
  tui = { accent = { fg = 118, bg = 233 } },
  ansi = { ["48;5;236"] = "48;5;237" },
})

local md = markdown.render("- item `code`")
local call = tool.render_call("read", { path = "README.md" }, nil)
return table.concat({
  tostring(md:find("\27[38;5;118m", 1, true) ~= nil),
  tostring(md:find("38;2;138;190;183", 1, true) ~= nil),
  tostring(call:find("\27[38;5;118m", 1, true) ~= nil),
  tostring(call:find("38;2;138;190;183", 1, true) ~= nil),
}, "|")
