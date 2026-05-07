--[==[psi-test
# Original: out must NOT start with '\n', AND must contain 'read README.md'. Folded.
expect = "true|true"
]==]
local out = require("psi.tui_runtime")._debug_tool_call_text_after_assistant()
local plain = require("psi.tui_text").strip_ansi(out)
return tostring(out:sub(1, 1) ~= "\n") .. "|"
  .. tostring(plain:find("read README.md", 1, true) ~= nil)
