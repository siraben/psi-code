--[[psi-test
# Original split asserts: encoded surrounded by "--", state path contains
# psi/sessions, encoded segment in path, ends in .jsonl. Folded.
expect = "true|true|true|true"
cwd = "project path"
env = { XDG_STATE_HOME = "{TMP}/state" }
]]
local s = require("psi.session_manager")
local path = s.ensure_default_path()
local encoded = s.encode_session_dir(psi.cwd())
local has_dashes = encoded:sub(1, 2) == "--" and encoded:sub(-2) == "--"
local state_root = TMP .. "/state/psi/sessions"
return tostring(has_dashes) .. "|"
  .. tostring(path:find(state_root, 1, true) ~= nil) .. "|"
  .. tostring(path:find("/" .. encoded .. "/", 1, true) ~= nil) .. "|"
  .. tostring(path:sub(-6) == ".jsonl")
