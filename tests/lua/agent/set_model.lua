--[[psi-test
contains = "openrouter/x/y|anthropic/fallback|ollama/local|true|ollama"
]]
local a = require("psi.agent_session")
a.set_model("openrouter/x/y")
local got = a.current_model("anthropic/fallback")
a.set_model(nil)
local cleared = a.current_model("anthropic/fallback")
a.configure({model = "ollama/local"})
local configured = a.current_model(nil)
local effective = a.effective_model(nil)
local desc = a.model_descriptor(nil)
local has_effective = effective ~= nil and effective ~= ""
return got .. "|" .. cleared .. "|" .. configured .. "|"
  .. tostring(has_effective) .. "|" .. desc.provider
