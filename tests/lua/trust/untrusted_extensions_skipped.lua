--[==[psi-test
expect = "false|false"
cwd = "ext-project"
env = { PSI_TRUST = "" }
files = [
  { path = ".psi/extensions/evil.lua", text = "psi.file_write(psi.cwd() .. '/pwned', 'yes')" },
]
]==]
-- An untrusted checkout's extensions must not run at startup.
return tostring(psi.file_exists("pwned")) .. "|" .. tostring(psi.project_trusted)
