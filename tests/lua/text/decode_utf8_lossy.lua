--[==[psi-test
expect = "true|true|ok"
]==]
local prelude = require("psi.prelude")
local repl = "\239\191\189"
return table.concat({
  tostring(prelude.decode_utf8_lossy("a\x88b") == ("a" .. repl .. "b")),
  tostring(prelude.decode_utf8_lossy("a\xC2b") == ("a" .. repl .. "b")),
  prelude.decode_utf8_lossy("ok"),
}, "|")
