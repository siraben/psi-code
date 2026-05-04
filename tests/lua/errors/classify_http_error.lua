--[[psi-test
contains = [
  "anthropic request failed (401)",
  "check your API key",
  "invalid key",
  "openrouter request failed (429)",
  "rate limited",
  "no such model",
  "provider is overloaded",
  "upstream exploded",
]
]]
local c = require("psi.providers.openai_compat").classify_http_error
local results = {}
results[1] = c(401,
  psi.json_encode({error = {message = "invalid key"}}),
  "anthropic")
results[2] = c(429, "", "openrouter")
results[3] = c(404,
  psi.json_encode({error = {message = "no such model"}}),
  "openrouter")
results[4] = c(503, "upstream exploded", "ollama")
return table.concat(results, "|")
