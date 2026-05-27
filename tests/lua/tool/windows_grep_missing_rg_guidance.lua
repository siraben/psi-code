--[==[psi-test
expect = "false|rg|9009|true|true|true"
env = { OS = "Windows_NT", TERM = "" }
]==]
local shell = require("psi.tool_shell")
local original = shell.run_streaming_argv
shell.run_streaming_argv = function()
  return { status = 9009, output = "", total_bytes = 0 }
end
local r = require("psi.tools").dispatch("grep", {
  pattern = "needle",
  path = TMP,
})
shell.run_streaming_argv = original
local err = r.error or ""
return table.concat({
  tostring(r.ok),
  r.extras.backend,
  tostring(r.extras.status),
  tostring(err:find("PowerShell", 1, true) ~= nil),
  tostring(err:find("Select-String", 1, true) ~= nil),
  tostring(err:find("Install rg", 1, true) ~= nil),
}, "|")
