--[==[psi-test
expect = "hdr=true usr=true ast=true tl=true msgs=3"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/a.jsonl"
psi.session_set_path(path)
s.append_user("one"); s.save()
s.append_assistant("two", {{type="text",text="two"}}); s.save()
s.append_tool_result("id1", "bash", "three", false); s.save()
local body = psi.read_file(path) or ""
local has_header = body:find([["type":"session"]], 1, true) ~= nil
local has_user   = body:find([["text":"one"]], 1, true) ~= nil
local has_asst   = body:find([[two]], 1, true) ~= nil
local has_tool   = body:find([[three]], 1, true) ~= nil
local msgs = 0
for _ in body:gmatch([["type":"message"]]) do msgs = msgs + 1 end
return string.format("hdr=%s usr=%s ast=%s tl=%s msgs=%d",
  tostring(has_header), tostring(has_user),
  tostring(has_asst), tostring(has_tool), msgs)
