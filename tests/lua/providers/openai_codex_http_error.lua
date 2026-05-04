--[[psi-test
contains = ["false|openai-codex request failed (401)", "nope"]
env = { PSI_AUTH_FILE = "{TMP}/codex-auth.json" }
]]
local a = require("psi.auth_storage")
a.set("openai-codex", {type="oauth", access="a", refresh="r", expires=9999999999999, accountId="acct"})
psi.http_stream_begin = function() return {} end
psi.http_stream_poll = function() return "{\"error\":{\"message\":\"nope\"}}", true end
psi.http_stream_finish = function() return 401 end
local ok, err = require("psi.sched").run(function()
  return require("psi.providers.openai_codex").run_turn({model="gpt-5.5"})
end)
return tostring(ok) .. "|" .. tostring(err)
