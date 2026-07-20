--[==[psi-test
expect = "true|true"
cwd = "system-files"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/SYSTEM.md", text = "Custom psi system base." },
  { path = ".psi/APPEND_SYSTEM.md", text = "Additional psi system guidance." },
]
]==]
local sp = require("psi.prompt").system_prompt()
return tostring(sp:find("Custom psi system base.", 1, true) ~= nil) .. "|"
  .. tostring(sp:find("Additional psi system guidance.", 1, true) ~= nil)
