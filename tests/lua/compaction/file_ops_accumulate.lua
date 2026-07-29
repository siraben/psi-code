--[==[psi-test
expect = "true|true|true|true"
]==]
local prompt = require("psi.prompt")
local session = require("psi.session_manager")

session.append_compaction("prior summary", {
  readFiles = { "old-read.txt" },
  modifiedFiles = { "old-write.txt" },
})
session.append_user("work")
session.append_assistant("", {
  { type = "tool_use", id = "read-1", name = "read", input = { path = "new-read.txt" } },
  { type = "tool_use", id = "write-1", name = "write", input = { path = "new-write.txt" } },
}, {})
session.append_user("recent")
session.append_assistant("done", { { type = "text", text = "done" } }, {})

local plan = session.prepare_compaction({ keep_recent_messages = 2 })
local formatted = prompt.format_file_operations(plan.read_files, plan.modified_files)
return table.concat({
  tostring(table.concat(plan.read_files, ","):find("old%-read.txt") ~= nil),
  tostring(table.concat(plan.read_files, ","):find("new%-read.txt") ~= nil),
  tostring(table.concat(plan.modified_files, ","):find("new%-write.txt") ~= nil),
  tostring(formatted:find("old%-write.txt") ~= nil),
}, "|")
