--[==[psi-test
expect = "true|true|true"
files = [
  { path = "tool.txt", text = "alpha beta" },
]
]==]
local path = TMP .. "/tool.txt"
local tools = require("psi.tools")
local render = require("psi.render")
local call = render.handle_event(
  "tool-call",
  { id = "w1", tool = "write", input = { path = path, content = "delta" } }
)
local r = tools.dispatch("write", { path = path, content = "delta" })
local result = render.handle_event("tool-result", { id = "w1", tool = "write", result = r })
return table.concat({
  tostring(call:find("write", 1, true) ~= nil),
  tostring(call:find("delta", 1, true) ~= nil),
  tostring(result:find("write completed", 1, true) ~= nil),
}, "|")
