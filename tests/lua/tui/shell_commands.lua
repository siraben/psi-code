--[==[psi-test
expect = "true|0|true|7|1|true|true"
]==]
local shell = require("psi.shell_commands")
local session = require("psi.session_manager")
local visible = shell.run(shell.parse("! printf shell-visible"))
local hidden = shell.run(shell.parse("!! printf shell-hidden; exit 7"))
local wire = require("psi.providers.openai_codex")._debug.response_input_from_session(session.messages(), "")
local empty = shell.run(shell.parse("!! "))
return table.concat({
  tostring(shell.parse("ordinary input") == nil),
  visible.status,
  tostring(visible.output == "shell-visible"),
  hidden.status,
  #wire,
  tostring(wire[1].content[1].text:find("shell-visible", 1, true) ~= nil),
  tostring(empty == nil),
}, "|")
