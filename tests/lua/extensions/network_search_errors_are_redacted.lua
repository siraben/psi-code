--[==[psi-test
expect = "true|true|true|true|true"

[env]
PSI_NETWORK_SEARCH_ENABLED = "1"
PSI_NETWORK_SEARCH_PROVIDER = "generic"
PSI_NETWORK_SEARCH_ENDPOINT = "https://search.test/"
PSI_NETWORK_SEARCH_API_KEY = "do-not-leak"
]==]
local index = 0
psi.http_post = function()
  index = index + 1
  if index == 1 then
    return 429, '{"error":"do-not-leak"}'
  elseif index == 2 then
    return nil, "Operation timed out: Authorization: Bearer do-not-leak"
  elseif index == 3 then
    return 200, "not-json-do-not-leak"
  end
  return 200, '{"unexpected":"do-not-leak"}'
end

local errors = {}
for _ = 1, 4 do
  local result = psi.tools.dispatch("network_search", { query = "q", count = 1 })
  errors[#errors + 1] = result.error
end
return table.concat({
  tostring(errors[1]:find("rate limited", 1, true) ~= nil),
  tostring(errors[2]:find("timed out", 1, true) ~= nil),
  tostring(errors[3]:find("invalid JSON", 1, true) ~= nil),
  tostring(errors[4]:find("unsupported response shape", 1, true) ~= nil),
  tostring(not table.concat(errors, "|"):find("do-not-leak", 1, true)),
}, "|")
