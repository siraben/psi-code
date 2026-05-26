--[==[psi-test
expect = "true|image/png|text|image|iVBORw0KGgoA"
]==]
local path = TMP .. "/tiny.png"
local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
assert(psi.file_write(path, png))
local r = require("psi.tools").dispatch("read", { path = path })
local content = r:get("content")
return table.concat({
  tostring(r.ok),
  tostring(r:get("mimeType")),
  content[1].type,
  content[2].type,
  content[2].data:sub(1, 12),
}, "|")
