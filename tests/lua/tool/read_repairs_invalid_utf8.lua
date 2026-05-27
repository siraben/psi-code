--[==[psi-test
expect = "true|true"
]==]
local path = TMP .. "/bad.bin"
local f = assert(io.open(path, "wb"))
f:write("a\x88b")
f:close()

local tools = require("psi.tools")
local result = tools.dispatch("read", { path = path })
local repl = "\239\191\189"
return table.concat({
  tostring(result.ok),
  tostring(result.extras.text == ("a" .. repl .. "b")),
}, "|")
