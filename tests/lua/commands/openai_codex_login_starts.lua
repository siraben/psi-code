--[==[psi-test
expect = "print|true|true|true|true"
]==]
local copied = ""
psi.stdout_write = function(s) copied = copied .. s end
local action = require("psi.slash_commands").handle("/login openai-codex")
return table.concat({
  action.kind,
  tostring(action.payload:find("https://auth.openai.com/oauth/authorize", 1, true) ~= nil),
  tostring(action.payload:find("/login openai-codex <redirect-url-or-code>", 1, true) ~= nil),
  tostring(action.payload:find("Copied auth URL to clipboard via OSC 52.", 1, true) ~= nil),
  tostring(copied:find("\27]52;", 1, true) ~= nil),
}, "|")
