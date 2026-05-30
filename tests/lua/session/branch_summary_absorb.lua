--[==[psi-test
contains = "ok=true loaded=3 has_summary=true leaf=true disk=true"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/branch-summary.jsonl"
psi.session_set_path(path)
s.append_user("root")
local root = s.leaf_id()
s.append_assistant("left work", {{type="text", text="left work"}}, {})
local left = s.leaf_id()
local ok, err = s.branch(root)
if not ok then return "branch-root-failed:" .. tostring(err) end
s.append_user("right work")
local right = s.leaf_id()
local entries, target, old_leaf = s.branch_entries_to_summarize(left)
local switched, summary_id = s.branch_with_summary(left, "summary of right branch", {
  fromId = old_leaf,
})
if not switched then return "branch-summary-failed:" .. tostring(summary_id) end
s.save()
s.load(path)
local has_summary = false
for _, m in ipairs(psi.session_messages()) do
  if m.role == "branch-summary" and m.text:find("summary of right branch", 1, true) then
    has_summary = true
  end
end
local body = psi.read_file(path) or ""
return string.format(
  "ok=%s loaded=%d has_summary=%s leaf=%s disk=%s target=%s old=%s right=%s",
  tostring(entries and #entries == 1),
  #psi.session_messages(),
  tostring(has_summary),
  tostring(s.leaf_id() == summary_id),
  tostring(body:find([["type":"branch_summary"]], 1, true) ~= nil),
  tostring(target == left),
  tostring(old_leaf == right),
  tostring(right ~= nil)
)
