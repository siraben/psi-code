--[==[psi-test
expect = "true|false"

[env]
PSI_NETWORK_SEARCH_ENABLED = "1"
PSI_NETWORK_SEARCH_PROVIDER = "generic"
PSI_NETWORK_SEARCH_ENDPOINT = "https://search.test/"
PSI_NETWORK_SEARCH_API_KEY = "env-secret"
PSI_AUTH_FILE = "{TMP}/auth.json"

[[files]]
path = "{TMP}/auth.json"
json = { network-search = { type = "api_key", key = "file-secret" } }
]==]
local header_text = nil
psi.http_post = function(_url, headers, _body)
  header_text = table.concat(headers, "\n")
  return 200, '{"results":[]}'
end
local result = psi.tools.dispatch("network_search", { query = "q", count = 1 })
return table.concat({
  tostring(result.ok and header_text:find("Bearer file-secret", 1, true) ~= nil),
  tostring(header_text:find("env-secret", 1, true) ~= nil),
}, "|")
