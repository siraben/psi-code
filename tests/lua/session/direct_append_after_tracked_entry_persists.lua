--[[psi-test
expect = "msgs=2 raw=true"
]]
local s = require("psi.session_manager")
local path = TMP .. "/direct.jsonl"
psi.session_set_path(path)
s.append_user("tracked")
s.save()
psi.session_append("assistant", "raw direct", nil, 1)
s.save()
local body = psi.read_file(path) or ""
local msgs = 0
for _ in body:gmatch([["type":"message"]]) do msgs = msgs + 1 end
return string.format("msgs=%d raw=%s", msgs, tostring(body:find("raw direct", 1, true) ~= nil))
