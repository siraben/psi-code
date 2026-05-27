--[==[psi-test
expect = "true|true|true"
]==]
local session = require("psi.session_manager")
local repl = "\239\191\189"

session.append_user("a\x88b")
session.append_tool_result("call_1", "bash", "c\x88d", false)
session.append_compaction("e\x88f")

local messages = session.messages()
return table.concat({
  tostring(messages[1].text == ("a" .. repl .. "b")),
  tostring(messages[2].text == ("c" .. repl .. "d")),
  tostring(messages[3].text == ("e" .. repl .. "f")),
}, "|")
