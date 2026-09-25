--[==[psi-test
expect = "false|true"
cwd = "skills-reader"
files = [
  { path = ".psi/skills/review/SKILL.md", text = "---\nname: review\ndescription: Review code\n---\nInstructions.\n" },
]
]==]
local tools = require("psi.tools")
tools.set_active({ "lua" })
local without_reader = require("psi.prompt").system_prompt()
tools.set_active({ "read" })
local with_reader = require("psi.prompt").system_prompt()
tools.set_active(nil)
return tostring(without_reader:find("<available_skills>", 1, true) ~= nil) .. "|"
  .. tostring(with_reader:find("<available_skills>", 1, true) ~= nil)
