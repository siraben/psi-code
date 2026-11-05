--[==[psi-test
expect = "true|true|false|tavily|2|example.com|First title|First [REDACTED] snippet|https://www.example.com/a|second.example|Second||true"

[env]
PSI_NETWORK_SEARCH_ENABLED = "1"
PSI_NETWORK_SEARCH_PROVIDER = "tavily"
PSI_NETWORK_SEARCH_ENDPOINT = "https://search.test/v1"
PSI_NETWORK_SEARCH_API_KEY = "test-secret"
]==]
local captured_headers = nil
local captured_body = nil
psi.http_post = function(url, headers, body)
  captured_headers = table.concat(headers, "\n")
  captured_body = body
  return 200, psi.json_encode({
    results = {
      {
        title = " First\ntitle ",
        url = "https://www.example.com/a",
        content = "First\t test-secret snippet",
      },
      { title = "duplicate", url = "https://www.example.com/a", content = "ignored" },
      { title = "bad", url = "file:///etc/passwd", content = "ignored" },
      { title = "Second", url = "https://second.example/b", content = "" },
    },
  })
end

local result = psi.tools.dispatch("network_search", { query = "lua search", count = 3 })
local out = result.extras
return table.concat({
  tostring(result.ok),
  tostring(captured_headers:find("Authorization: Bearer test-secret", 1, true) ~= nil),
  tostring(captured_body:find("test-secret", 1, true) ~= nil),
  out.provider,
  tostring(out.count),
  out.sources[1].source,
  out.sources[1].title,
  out.sources[1].snippet,
  out.sources[1].url,
  out.sources[2].source,
  out.sources[2].title,
  out.sources[2].snippet,
  tostring(psi.json_encode(out):find("test-secret", 1, true) == nil),
}, "|")
