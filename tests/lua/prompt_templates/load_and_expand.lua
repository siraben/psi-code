--[==[psi-test
name = "prompt_templates/load_and_expand"
expect = "true|true|true|Hello Alice. All: Alice Bob Carol Dave. Skip one: Bob Carol Dave. Two from 2: Bob Carol."
env = { PSI_PROMPTS_DIR = "{TMP}/tplprompts" }
files = [
  { path = "tplprompts/greet.md", text = "---\ndescription: Say hello to $1\nargument-hint: <name>\n---\nHello $1. All: $@. Skip one: ${@:2}. Two from 2: ${@:2:2}.\n" },
]
]==]
local pt = require("psi.prompt_templates")
pt.load()
local list = pt.list()
local a = (#list == 1)
local t = list[1]
local b = (t.description == "Say hello to $1")
local c = (t.argument_hint == "<name>")
local expanded = pt.expand("/greet Alice Bob Carol Dave")
return tostring(a) .. "|" .. tostring(b) .. "|"
  .. tostring(c) .. "|" .. (expanded or "<nil>")
