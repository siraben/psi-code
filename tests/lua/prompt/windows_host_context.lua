--[==[psi-test
contains = [
  "Host context:",
  "Host OS: Windows",
  "Shell tool backend: cmd.exe /d /c",
  "Execute short inline Windows shell commands",
  "use PowerShell only when cmd cannot express the task compactly",
]
not_contains = ".ps1/.cmd/.bat helper files"
env = { OS = "Windows_NT", TERM = "" }
]==]
return require("psi.prompt").system_prompt()
