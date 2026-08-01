--[==[psi-test
expect = "true|true|goal (active): Finish the migration"
]==]
local commands = require("psi.slash_commands")
local session = require("psi.session_manager")

local path = TMP .. "/goal-compaction.jsonl"
psi.session_set_path(path)
commands.handle("/goal Finish the migration")
session.append_user("old question")
session.append_assistant("old answer", { { type = "text", text = "old answer" } }, {})
session.append_user("recent question")
session.append_assistant("recent answer", { { type = "text", text = "recent answer" } }, {})

local plan = assert(session.prepare_compaction({ keep_recent_messages = 2 }))
local compacted = session.do_compact(plan, "summary")
assert(session.save(path))

psi.session_clear()
session.reset_entry_chain()
local loaded = session.load(path)
local goal = commands.handle("/goal show")
return table.concat({ tostring(compacted), tostring(loaded), goal.payload }, "|")
