--[==[psi-test
expect = "Hello world|nil|Hello again"
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
local after_disable = templates.expand("/extra-template world")
templates.load_path(TMP .. "/extra-template.md")
local explicit_after_disable = templates.expand("/extra-template again")
return tostring(expanded) .. "|"
  .. tostring(after_disable) .. "|"
  .. tostring(explicit_after_disable)
