--[==[psi-test
expect = "true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local render = require("psi.render")
local text = require("psi.tui_text")

ansi.enabled = true
ansi.color_enabled = true

local out = render.render_tool_result({
  id = "bash-cr-progress",
  tool = "bash",
  result = {
    ok = true,
    status = 0,
    output = "Downloading 1%\rDownloading 2%\rDone\ncomplete\n",
  },
})
local plain = text.strip_ansi(out)

return table.concat({
  tostring(plain:find("\r", 1, true) == nil),
  tostring(plain:find("Downloading 1%", 1, true) == nil),
  tostring(plain:find("Downloading 2%", 1, true) == nil),
  tostring(plain:find("Done", 1, true) ~= nil),
  tostring(plain:find("complete", 1, true) ~= nil),
}, "|")
