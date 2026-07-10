--[==[psi-test
expect = "medium|low|xhigh|max|true"
]==]
local d = require("psi.providers.openai_codex")._debug
local a = d.request_body({model="gpt-5.5", messages={}})
local b = d.request_body({model="gpt-5.6-terra", messages={}, thinking_level="minimal"})
local c = d.request_body({model="gpt-5.6-terra", messages={}, thinking_level="xhigh"})
local m = d.request_body({model="gpt-5.6-terra", messages={}, thinking_level="max"})
local e = d.request_body({model="gpt-5.5", messages={}, thinking_level="off"})
return a.reasoning.effort .. "|" .. b.reasoning.effort .. "|"
  .. c.reasoning.effort .. "|" .. m.reasoning.effort .. "|" .. tostring(e.reasoning == nil)
