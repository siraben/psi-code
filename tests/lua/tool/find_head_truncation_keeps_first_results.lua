--[==[psi-test
expect = "true|false|true"
]==]
-- fd does not guarantee filesystem traversal order, so provide a stable
-- backend stream and verify that find keeps its beginning when truncating.
local rows = {}
for i = 0, 699 do
  rows[#rows + 1] = string.format("a%04d_%s", i, string.rep("x", 120))
end
local raw = table.concat(rows, "\n")
local shell = require("psi.tool_shell")
local original = shell.run_streaming_argv
shell.run_streaming_argv = function()
  return { output = raw, status = 0, total_bytes = #raw }
end
local r = require("psi.tools").dispatch("find", {pattern = "*", path = ".", limit = 700})
shell.run_streaming_argv = original
local o = r.extras.output or ""
return tostring(o:find("a0000_", 1, true) ~= nil) .. "|"
  .. tostring(o:find("a0699_", 1, true) ~= nil) .. "|"
  .. tostring(r.extras.truncated)
