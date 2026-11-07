--[==[psi-test
expect = "ok"
env = { HOME = "" }
]==]
local commands = require("psi.slash_commands")
for _, command in ipairs({"/login anthropic", "/login anthropic fake-test-key"}) do
  local action = commands.handle(command)
  assert(action.payload:find("HOME or PSI_AUTH_FILE", 1, true), "login must fail descriptively, not concatenate nil")
end
assert(not psi.file_exists(".psi/auth.json"))
return "ok"
