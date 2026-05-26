--[==[psi-test
expect = "51200|true"
]==]
local path = TMP .. "/large.txt"
assert(psi.file_write(path, string.rep("a", 60 * 1024)))
local r = require("psi.tools").dispatch("read", { path = path })
local text = r:get("text") or ""
local body = text:match("\n(.*)$") or text
return tostring(#body) .. "|" .. tostring(text:find("Byte limit reached", 1, true) ~= nil)
