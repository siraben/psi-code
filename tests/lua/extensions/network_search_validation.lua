--[==[psi-test
expect = "false|false|false|true|true|true|512|8"

[env]
PSI_NETWORK_SEARCH_ENABLED = "1"
PSI_NETWORK_SEARCH_PROVIDER = "generic"
PSI_NETWORK_SEARCH_ENDPOINT = "https://search.test/"
PSI_NETWORK_SEARCH_API_KEY = "secret"
]==]
local called = false
psi.http_post = function()
  called = true
  return 200, '{"results":[]}'
end
local long = psi.tools.dispatch("network_search", { query = string.rep("x", 513), count = 1 })
local count = psi.tools.dispatch("network_search", { query = "q", count = 9 })
local count_type = psi.tools.dispatch("network_search", { query = "q", count = "2" })
local schema = psi.tools.find("network_search").input_schema.properties
return table.concat({
  tostring(long.ok),
  tostring(count.ok),
  tostring(count_type.ok),
  tostring(long.error:find("byte limit", 1, true) ~= nil),
  tostring(count_type.error:find("number", 1, true) ~= nil),
  tostring(not called),
  tostring(schema.query.maxLength),
  tostring(schema.count.maximum),
}, "|")
