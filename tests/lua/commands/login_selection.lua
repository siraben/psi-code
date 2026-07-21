--[==[psi-test
expect = "true|true|true|true|true"
]==]
local commands = require("psi.slash_commands")
local methods = commands.handle("/login").payload
local providers = commands.handle("/login api-key").payload
return table.concat({
  tostring(methods:find("Select authentication method:", 1, true) ~= nil),
  tostring(methods:find("/login oauth", 1, true) ~= nil),
  tostring(methods:find("/login api-key", 1, true) ~= nil),
  tostring(providers:find("/login api-key anthropic", 1, true) ~= nil),
  tostring(providers:find("/login api-key openrouter", 1, true) ~= nil),
}, "|")
