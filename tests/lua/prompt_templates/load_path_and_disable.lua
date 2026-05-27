--[==[psi-test
expect = "Hello world|nil"
files = [
  { path = "extra-template.md", text = "Hello $1" },
]
]==]
local templates = require("psi.prompt_templates")
templates.set_enabled(true)
templates.clear()
templates.load_path(TMP .. "/extra-template.md")
local expanded = templates.expand("/extra-template world")
templates.set_enabled(false)
return tostring(expanded) .. "|" .. tostring(templates.expand("/extra-template world"))
