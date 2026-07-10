--[==[psi-test
expect = "true|true|true|true|true"
cwd = "fork project"
env = { XDG_STATE_HOME = "{TMP}/state" }
]==]
local prelude = require("psi.prelude")
local s = require("psi.session_manager")

local parent = s.ensure_default_path()
s.append_user("fork me")

local action = require("psi.slash_commands").handle("/fork 1")
local out = tostring(action.payload or ""):match(" to (.+)$") or ""
local expected_dir = s.session_dir_for_cwd(psi.cwd())
local body = psi.read_file(out) or ""
local header = prelude.safe_json_decode(body:match("([^\n]+)") or "", {})

local in_state_dir = expected_dir and out:sub(1, #expected_dir + 1) == expected_dir .. "/"
local not_cwd_sessions = out:find(psi.cwd() .. "/sessions/", 1, true) == nil

return table.concat({
  tostring(action.kind == "print"),
  tostring(in_state_dir),
  tostring(not_cwd_sessions),
  tostring(psi.file_exists(out)),
  tostring(header.parentSession == parent),
}, "|")
