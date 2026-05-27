--[==[psi-test
expect = "false|9009|fd"
files = [
  { path = "nested", mkdir = true },
  { path = "nested/a.md", text = "alpha" },
]
]==]
local shell = require("psi.tool_shell")
local platform = require("psi.platform")
local original = shell.run_streaming_argv
local original_is_windows = platform.is_windows
shell.run_streaming_argv = function()
  return { status = 9009, output = "", total_bytes = 0 }
end
platform.is_windows = function()
  return false
end
local r = require("psi.tools").dispatch("find", { pattern = "*.md", path = TMP, limit = 10 })
shell.run_streaming_argv = original
platform.is_windows = original_is_windows
return tostring(r.ok) .. "|" .. tostring(r.extras.status) .. "|" .. r.extras.backend
