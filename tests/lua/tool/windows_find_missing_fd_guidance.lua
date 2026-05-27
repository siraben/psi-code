--[==[psi-test
expect = "false|fd|9009|true|true|true"
env = { OS = "Windows_NT", TERM = "" }
]==]
local shell = require("psi.tool_shell")
local original = shell.run_streaming_argv
shell.run_streaming_argv = function()
  return { status = 9009, output = "", total_bytes = 0 }
end
local r = require("psi.tools").dispatch("find", {
  pattern = "*.md",
  path = TMP,
})
shell.run_streaming_argv = original
local err = r.error or ""
return table.concat({
  tostring(r.ok),
  r.extras.backend,
  tostring(r.extras.status),
  tostring(err:find("PowerShell", 1, true) ~= nil),
  tostring(err:find("Get-ChildItem", 1, true) ~= nil),
  tostring(err:find("Install fd", 1, true) ~= nil),
}, "|")
