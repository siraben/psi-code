--[==[psi-test
env = { PSI_OPENROUTER_MODELS_CACHE = "{TMP}/missing-model-cache.json" }
expect = "0|true"
]==]
local models = require("psi.providers.openrouter_models")
models._reset_for_tests()
local calls = 0
local saved = psi.http_get
psi.http_get = function()
  calls = calls + 1
  return 500, ""
end
local line = require("psi.tui_status").status_line({
  model = "openrouter/vendor/model-not-cached",
  thinking_level = "high",
  busy = false,
  scroll = 0,
})
psi.http_get = saved
return tostring(calls)
  .. "|"
  .. tostring(line:find("model:vendor/model-not-cached", 1, true) ~= nil)
