--[==[psi-test
# Original: idem == "true" AND set == "true" AND path contains "/psi/sessions/"
# AND path ends with ".jsonl". Folded.
expect = "true|true|true|true"
]==]
local s = require("psi.session_manager")
local first = s.ensure_default_path()
local second = s.ensure_default_path()
local idem = (first == second)
local set = (psi.session_path() == first)
local has_dir = first and first:find("/psi/sessions/", 1, true) ~= nil
local has_ext = first and first:sub(-6) == ".jsonl"
return tostring(idem) .. "|" .. tostring(set) .. "|"
  .. tostring(has_dir) .. "|" .. tostring(has_ext)
