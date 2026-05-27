--[==[psi-test
contains = [
  "cmd.exe /d /c",
  "short inline Windows shell commands",
  "dir, where, type",
  "Do not use Unix-only commands",
  "Use PowerShell only when cmd cannot express the task compactly",
]
not_contains = ".ps1/.cmd/.bat helper files"
env = { OS = "Windows_NT", TERM = "" }
]==]
local tools = require("psi.tools")
local spec = tools.find("bash")
return table.concat({
  spec.description or "",
  spec.prompt_snippet or "",
  table.concat(spec.guidelines or {}, "\n"),
}, "\n")
