--[==[psi-test
expect = "true|true|true|true"
]==]
local tool = require("psi.tools").find("read")
return table.concat({
  tostring(tool.description:find("images", 1, true) ~= nil),
  tostring(tool.description:find("does not auto-resize", 1, true) ~= nil),
  tostring(tool.description:find("2000 lines or 50KB", 1, true) ~= nil),
  tostring(tool.description:find("continue with offset until complete", 1, true) ~= nil),
}, "|")
