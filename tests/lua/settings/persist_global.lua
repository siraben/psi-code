--[==[psi-test
expect = "true|true|true|keep"
env = { XDG_CONFIG_HOME = "{TMP}/config" }
files = [
  { path = "config/psi/settings.json", json = { untouched = "keep", tui = { prompt = { max_rows = 9 } } } },
]
]==]
local settings = require("psi.settings_manager")
local ok = settings.set_global("hideThinkingBlock", true)
local body = psi.json_decode(psi.read_file(settings.global_path()))
return table.concat({
  tostring(ok),
  tostring(settings.get("hideThinkingBlock", false)),
  tostring(body.tui.prompt.max_rows == 9),
  tostring(body.untouched),
}, "|")
