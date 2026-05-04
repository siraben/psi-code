--[[psi-test
expect = "msgs=0 stale=false"
]]
local s = require("psi.session_manager")
local path = TMP .. "/clear.jsonl"
psi.session_set_path(path)
s.append_user("stale")
s.save()
psi.session_clear()
local ok, err = s.save()
if not ok then return "save-failed:" .. tostring(err) end
local body = psi.read_file(path) or ""
local msgs = 0
for _ in body:gmatch([["type":"message"]]) do msgs = msgs + 1 end
return string.format("msgs=%d stale=%s", msgs, tostring(body:find("stale", 1, true) ~= nil))
