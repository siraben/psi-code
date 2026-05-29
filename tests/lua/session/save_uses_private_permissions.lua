--[==[psi-test
expect = "true|600"
]==]
local s = require("psi.session_manager")
local path = TMP .. "/private-session.jsonl"
psi.session_set_path(path)
s.append_user("secret-ish")
local ok = s.save()
local stat = psi.process_run_argv({"stat", "-c", "%a", path})
return tostring(ok) .. "|" .. (stat.output or ""):gsub("%s+$", "")
