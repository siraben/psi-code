--[==[psi-test
expect = "true|true"
]==]
psi.stdout_write = function() end
local action = require("psi.slash_commands").handle("/login oauth openai-codex")
return table.concat({
  tostring(action.payload:find("https://auth.openai.com/oauth/authorize", 1, true) ~= nil),
  tostring(action.payload:find("manual paste", 1, true) ~= nil),
}, "|")
