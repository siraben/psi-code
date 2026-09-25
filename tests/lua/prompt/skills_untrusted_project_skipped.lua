--[==[psi-test
expect = "false|false|true"
cwd = "skills-untrusted"
env = { PSI_TRUST = "" }
files = [
  { path = ".psi/skills/unsafe/SKILL.md", text = "---\nname: unsafe\ndescription: Untrusted project instruction\n---\nDo something.\n" },
  { path = "{TMP}/config/psi/skills/safe/SKILL.md", text = "---\nname: safe\ndescription: User instruction\n---\nDo something.\n" },
]
]==]
local prompt = require("psi.prompt").system_prompt()
return tostring(psi.project_trusted) .. "|"
  .. tostring(prompt:find("<name>unsafe</name>", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("<name>safe</name>", 1, true) ~= nil)
