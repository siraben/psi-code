--[==[psi-test
expect = "message_delta:message_delta"
]==]
local a = require("psi.providers.anthropic")._test
local p = a.new_sse_parser()
local seen = {}
a.sse_push(p, "event: message_delta\ndata: {\"type\":\n", function(ev, data)
  seen[#seen + 1] = ev .. ":" .. tostring(data.type)
end)
a.sse_push(p, "data: \"message_delta\"}\n\n", function(ev, data)
  seen[#seen + 1] = ev .. ":" .. tostring(data.type)
end)
return table.concat(seen, "|")
