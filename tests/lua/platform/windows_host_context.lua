--[==[psi-test
contains = [
  "Host OS: Windows",
  "Shell tool backend: cmd.exe /d /c",
  "Use Windows command syntax",
  "Prefer short inline cmd.exe commands",
  "C:\\",
]
not_contains = ".ps1/.cmd/.bat helper files"
env = { OS = "Windows_NT", TERM = "" }
]==]
local platform = require("psi.platform")
local saved = psi.runtime_info
psi.runtime_info = function()
  return { ["current-working-directory"] = "/C/Users/siraben/Desktop" }
end
local text = table.concat(platform.host_context_lines(), "\n")
psi.runtime_info = saved
return text
