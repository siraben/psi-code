--[==[psi-test
expect = "second=true compacted=true active=true"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/compact-branches.jsonl"
psi.session_set_path(path)
local p = require("psi.prelude")
s.append_system({
  role = "system",
  content = "opaque base",
  timestamp = 1,
  sections = p.ordered_object(
    { "preamble", "obsolete", "vendor_notes" },
    { preamble = "base", obsolete = "old", vendor_notes = "branch notes" }
  ),
  toolsAdded = {
    { name = "foreign_tool", description = "historical only", parameters = { type = "object" } },
  },
})
s.append_system({
  role = "system",
  content = "base addendum",
  timestamp = 2,
  sections = p.ordered_object(
    { "obsolete", "rules" },
    { obsolete = psi.json_null, rules = "rules" }
  ),
})
s.append_thinking_level_change("high")
s.append_user("root")
local root = s.leaf_id()
s.append_assistant("first", { { type = "text", text = "first" } }, {})
local first = s.leaf_id()
local ok = s.branch(root)
if not ok then
  return "branch-root-failed"
end
s.append_user("second")
local second = s.leaf_id()
s.save()
ok = s.branch(first)
if not ok then
  return "branch-first-failed"
end
s.do_compact(1, "summary")
local projected = s.projection()
assert(projected.entries[1].source_entry.firstKeptEntryId == first)
assert(projected.entries[2].source_entry.id == first, "compaction preserves kept IDs")
assert(#projected.messages == 3 and projected.messages[3].content[1].text == "first")
s.save()
s.load(path)
local compact_leaf = s.leaf_id()
local second_ok = s.branch(second)
local compact_ok = s.branch(compact_leaf)
local active = psi.session_messages()
assert(s.current_thinking_level() == "high")
local system = s.current_system()
assert(system.content == "opaque base\n\nbase addendum")
assert(system.sections.obsolete == nil and system.sections.vendor_notes == "branch notes")
assert(
  table.concat(require("psi.session_projection").keys(system.sections), "|")
    == "preamble|vendor_notes|rules"
)
assert(require("psi.tool_registry").find("foreign_tool") == nil)
require("psi.prompt").prepare_checkpoint()
assert(s.current_system().sections.vendor_notes == "branch notes")
for _, tool in ipairs(s.current_system().toolsAdded) do
  assert(tool.name ~= "foreign_tool")
end
local leaf_after_checkpoint = s.leaf_id()
require("psi.prompt").prepare_checkpoint()
assert(s.leaf_id() == leaf_after_checkpoint, "unchanged checkpoints are not appended")
local has_summary = false
for _, m in ipairs(active) do
  if m.role == "compaction-summary" and m.text == "summary" then
    has_summary = true
  end
end
return "second="
  .. tostring(second_ok)
  .. " compacted="
  .. tostring(compact_ok and has_summary)
  .. " active="
  .. tostring(#active >= 2)
