--[==[psi-test
expect = "medium|low|xhigh|true"
]==]
local d = require("psi.providers.openai_codex")._debug
local a = d.request_body({model="gpt-5.5", messages={}})
local b = d.request_body({model="gpt-5.5", messages={}, thinking_level="minimal"})
local c = d.request_body({model="gpt-5.5", messages={}, thinking_level="xhigh"})
local e = d.request_body({model="gpt-5.5", messages={}, thinking_level="off"})
return a.reasoning.effort .. "|" .. b.reasoning.effort .. "|"
  .. c.reasoning.effort .. "|" .. tostring(e.reasoning == nil)
