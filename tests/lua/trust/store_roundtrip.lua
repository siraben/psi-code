--[==[psi-test
expect = "true|true|true|false|true"
cwd = "trust-store"
files = [
  { path = ".psi/settings.json", json = { marker = "x" } },
]
]==]
local trust = require("psi.trust_manager")
local cwd = psi.cwd()
local needs = trust.requires_prompt(cwd)
local set_ok = trust.set(cwd, true) and trust.get(cwd) == true
local trusted = trust.resolve(false)
local clear_ok = trust.set(cwd, false)
local untrusted = trust.resolve(false)
return tostring(needs) .. "|" .. tostring(set_ok) .. "|" .. tostring(trusted) .. "|"
  .. tostring(untrusted) .. "|" .. tostring(clear_ok)
