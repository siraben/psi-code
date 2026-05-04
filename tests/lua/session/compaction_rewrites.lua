--[[psi-test
expect = "ok"
]]
local s = require("psi.session_manager")
local path = TMP .. "/c.jsonl"
psi.session_set_path(path)
for i = 1, 10 do s.append_user("msg " .. i) end
s.save()
local before = #(psi.read_file(path) or "")
s.do_compact(2, "summary")
s.save()
local after = #(psi.read_file(path) or "")
return (after < before) and "ok" or ("bad before=" .. before .. " after=" .. after)
