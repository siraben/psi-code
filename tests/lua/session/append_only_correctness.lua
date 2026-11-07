--[==[psi-test
expect = "hdr=true usr=true ast=true tl=true msgs=3"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/a.jsonl"
psi.session_set_path(path)
s.append_user("one")
s.save()
s.append_assistant("two", { { type = "text", text = "two" } })
s.save()
s.append_tool_result("id1", "bash", "three", false)
s.save()
local body = psi.read_file(path) or ""
local has_header = body:find([["type":"session"]], 1, true) ~= nil
local has_user = body:find([["text":"one"]], 1, true) ~= nil
local has_asst = body:find([[two]], 1, true) ~= nil
local has_tool = body:find([[three]], 1, true) ~= nil
local msgs = 0
for _ in body:gmatch([["type":"message"]]) do
  msgs = msgs + 1
end
local header_line, rest = body:match("([^\n]+)\n(.*)")
local header = psi.json_decode(header_line, true)
header.future = { value = psi.json_null }
header.leafId = "foreign-state"
local opaque = '{"type":"future_state","id":"foreign-state","parentId":"'
  .. s.leaf_id()
  .. '","opaque":{"value":null,"items":[]}}'
assert(psi.file_write(path, psi.json_encode(header) .. "\n" .. rest .. opaque .. "\n"))
assert(s.load(path))
assert(#s.projection().messages == 3, "opaque state is not model context")
local copy = TMP .. "/copy.jsonl"
assert(s.save(copy))
local saved = psi.read_file(copy)
local new_header = psi.json_decode(saved:match("[^\n]+"), true)
assert(new_header.future.value == psi.json_null)
local found = false
for line in saved:gmatch("[^\n]+") do
  local entry = psi.json_decode(line, true)
  if entry.id == "foreign-state" then
    assert(entry.type == "future_state" and entry.opaque.value == psi.json_null)
    assert(psi.json_encode(entry.opaque.items) == "[]")
    found = true
  end
end
assert(found, "opaque entries survive export")
return string.format(
  "hdr=%s usr=%s ast=%s tl=%s msgs=%d",
  tostring(has_header),
  tostring(has_user),
  tostring(has_asst),
  tostring(has_tool),
  msgs
)
