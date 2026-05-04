--[==[psi-test
contains = ["prompt templates", "/review [scope]", "Review staged changes"]
env = { PSI_PROMPTS_DIR = "{TMP}/help-prompts" }
files = [
  { path = "help-prompts/review.md", text = "---\ndescription: Review staged changes\nargument-hint: [scope]\n---\nReview $@.\n" },
]
]==]
local pt = require("psi.prompt_templates")
local c = require("psi.slash_commands")
pt.load()
return c.help_text()
