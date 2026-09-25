--[==[psi-test
expect = "true|true|true|false|false"
cwd = "skills-project"
files = [
  { path = ".psi/skills/review/SKILL.md", text = "---\nname: review\ndescription: Review code carefully\n---\nRead every diff.\n" },
  { path = "{TMP}/config/psi/skills/explain/SKILL.md", text = "---\nname: explain\ndescription: Explain unfamiliar code\n---\nExplain it.\n" },
  { path = ".psi/skills/manual/SKILL.md", text = "---\nname: manual\ndescription: Explicit use only\ndisable-model-invocation: true\n---\nManual.\n" },
]
]==]
local prompt = require("psi.prompt").system_prompt()
return tostring(prompt:find("<name>review</name>", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("<name>explain</name>", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find(".psi/skills/review/SKILL.md", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("<name>manual</name>", 1, true) ~= nil) .. "|"
  .. tostring(prompt:find("Read every diff.", 1, true) ~= nil)
