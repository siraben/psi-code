--[==[psi-test
expect = "second=true compacted=true active=true"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/compact-branches.jsonl"
psi.session_set_path(path)
s.append_user("root")
local root = s.leaf_id()
s.append_assistant("first", {{ type = "text", text = "first" }}, {})
local first = s.leaf_id()
local ok = s.branch(root)
if not ok then return "branch-root-failed" end
s.append_user("second")
local second = s.leaf_id()
s.save()
ok = s.branch(first)
if not ok then return "branch-first-failed" end
s.do_compact(1, "summary")
s.save()
s.load(path)
local compact_leaf = s.leaf_id()
local second_ok = s.branch(second)
local compact_ok = s.branch(compact_leaf)
local active = psi.session_messages()
local has_summary = false
for _, m in ipairs(active) do
  if m.role == "compaction-summary" and m.text == "summary" then
    has_summary = true
  end
end
return "second=" .. tostring(second_ok)
  .. " compacted=" .. tostring(compact_ok and has_summary)
  .. " active=" .. tostring(#active >= 2)
