--[==[psi-test
expect = "resume-picker|nil|resume|/tmp/session.jsonl"
]==]
local commands = require("psi.slash_commands")
local picker = commands.handle("/resume")
local explicit = commands.handle("/resume /tmp/session.jsonl")
return tostring(picker.kind) .. "|"
  .. tostring(picker.payload) .. "|"
  .. tostring(explicit.kind) .. "|"
  .. tostring(explicit.payload)
