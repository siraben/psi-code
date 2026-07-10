--[==[psi-test
expect = "1|1|1"
cwd = "reload-extension-registries"
files = [
  { path = ".psi/extensions/hook.lua", text = '''
return function(psi)
  psi.tools.add_after_hook(function()
    psi._hook_hits = (psi._hook_hits or 0) + 1
  end)
  psi.events.on("reload-test", function()
    psi._event_hits = (psi._event_hits or 0) + 1
  end)
  psi.prompt.register_transformer(function(prompt)
    return prompt .. "\nEXTENSION_RELOAD_MARK"
  end)
end
''' },
]
]==]
local commands = require("psi.slash_commands")
commands.handle("/reload")
commands.handle("/reload")
require("psi.tools").dispatch("bash", { command = "printf ok" })
psi.events.emit("reload-test", {})
local prompt = require("psi.prompt").system_prompt()
local _, prompt_count = prompt:gsub("EXTENSION_RELOAD_MARK", "")
return tostring(psi._hook_hits or 0) .. "|"
  .. tostring(psi._event_hits or 0) .. "|"
  .. tostring(prompt_count)
