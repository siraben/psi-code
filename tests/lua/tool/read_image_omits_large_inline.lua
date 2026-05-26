--[==[psi-test
expect = "true|nil|true"
]==]
local path = TMP .. "/large.png"
local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
assert(psi.file_write(path, png .. string.rep("x", 3538944)))
local r = require("psi.tools").dispatch("read", { path = path })
local content = r:get("content")
return table.concat({
  tostring(r.ok),
  tostring(content[2]),
  tostring((r:get("image_omitted") or ""):find("does not auto-resize", 1, true) ~= nil),
}, "|")
