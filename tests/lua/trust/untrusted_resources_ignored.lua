--[==[psi-test
expect = "none|true|false"
cwd = "untrusted-project"
env = { PSI_TRUST = "" }
files = [
  { path = ".psi/settings.json", json = { marker = { value = "repo" } } },
  { path = ".psi/SYSTEM.md", text = "Repo-controlled prompt." },
]
]==]
-- No stored decision and no override: project resources stay disabled.
local settings = require("psi.settings_manager")
local resources = require("psi.resource_loader")
local prompt_file = resources.system_prompt_file()
return tostring(settings.get("marker.value", "none")) .. "|"
  .. tostring(prompt_file == nil) .. "|"
  .. tostring(psi.project_trusted)
