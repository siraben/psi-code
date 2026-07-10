--[==[psi-test
expect = "true|true"
]==]
local commands = require("psi.slash_commands")
local session = require("psi.session_manager")
session.append_user("root")
local branch = commands.handle("/branch")
local tree = commands.handle("/tree")
return tostring(branch.payload == tree.payload) .. "|"
  .. tostring(tree.payload:find("session tree", 1, true) ~= nil)
