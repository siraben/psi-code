--[==[psi-test
expect = "true|true|true"
]==]
-- The pi-light tool block must pair a pale success/pending background
-- with dark title text. The regression this guards against was a dark
-- green background (48;5;22) left unremapped under a light terminal,
-- which rendered black-on-dark-green and was unreadable.
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local te = require("psi.tui_components.tool_execution")

ansi.enabled = true
ansi.color_enabled = true
theme.use("pi-light")

local call = te.render_call("bash", { command = "ls -la" })
return table.concat({
  -- pale pending tint #e8e8f0
  tostring(call:find("\27[48;2;232;232;240m", 1, true) ~= nil),
  -- dark title text #1f2328 (bold)
  tostring(call:find("\27[1;38;2;31;35;40m", 1, true) ~= nil),
  -- the raw dark-green success palette must not leak through
  tostring(call:find("\27[48;5;22m", 1, true) == nil),
}, "|")
