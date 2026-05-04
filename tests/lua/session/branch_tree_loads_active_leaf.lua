--[[psi-test
# Folded: original also asserted on-disk file message count == 3 after branch.
# The Lua reads the file back and includes the count in the return string.
expect = "loaded=2 first=false second=true branched=2 leaf=true|3"
]]
local s = require("psi.session_manager")
local path = TMP .. "/branch.jsonl"
psi.session_set_path(path)
s.append_user("root")
local root = s.leaf_id()
local root_tree = s.branch_tree_text()
if not root_tree:find(root:sub(1, 8), 1, true) then return "missing-root" end
s.append_assistant("first", {{type="text", text="first"}}, {})
local first = s.leaf_id()
local ok, err = s.branch(root)
if not ok then return "branch-root-failed:" .. tostring(err) end
s.append_user("second")
s.save()
s.load(path)
local loaded = psi.session_messages()
local saw_first = false
local saw_second = false
for _, m in ipairs(loaded) do
  if m.text == "first" then saw_first = true end
  if m.text == "second" then saw_second = true end
end
local ok2, err2 = s.branch(first)
if not ok2 then return "branch-first-failed:" .. tostring(err2) end
local branched = psi.session_messages()
local body = psi.read_file(path) or ""
local msg_count = 0
for _ in body:gmatch([["type":"message"]]) do msg_count = msg_count + 1 end
return string.format("loaded=%d first=%s second=%s branched=%d leaf=%s|%d",
  #loaded, tostring(saw_first), tostring(saw_second), #branched,
  tostring(s.leaf_id() == first), msg_count)
