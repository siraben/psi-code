--[==[psi-test
expect = "true|true"
]==]
local path = TMP .. "/tiny.png"
local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
assert(psi.file_write(path, png))
local r = require("psi.tools").dispatch(
  "read",
  { path = path },
  { provider = "openai-codex", model = "gpt-5.3-codex-spark" }
)
return table.concat({
  tostring(r.ok),
  tostring((r:get("text") or ""):find("does not support images", 1, true) ~= nil),
}, "|")
