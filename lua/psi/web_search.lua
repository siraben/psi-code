-- psi.web_search: provider-neutral network search over the libcurl-backed
-- psi.http_request primitive. The tool surface stays stable while
-- provider-specific request/response mapping lives here.

local prelude = require("psi.prelude")
local settings = require("psi.settings")

local M = {}

local PROVIDER_ENV = "PSI_WEB_SEARCH_PROVIDER"
local PROVIDER_DEFAULT = "brave"
local BRAVE_API_KEY_ENVS = { "BRAVE_SEARCH_API_KEY", "PSI_BRAVE_SEARCH_API_KEY" }
local BRAVE_BASE_URL_ENV = "PSI_BRAVE_SEARCH_BASE_URL"
local BRAVE_BASE_URL_DEFAULT = "https://api.search.brave.com/res/v1/web/search"
local TIMEOUT_ENV = "PSI_WEB_SEARCH_TIMEOUT_MS"
local MAX_BYTES_ENV = "PSI_WEB_SEARCH_MAX_RESPONSE_BYTES"
local LIMIT_DEFAULT = 5
local LIMIT_MAX = 10
local TIMEOUT_DEFAULT = 15000
local MAX_BYTES_DEFAULT = 262144

local function env(name)
  local value = os.getenv(name)
  if value and value ~= "" then
    return value
  end
  return nil
end

local function env_any(names)
  for _, name in ipairs(names) do
    local value = env(name)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function setting(path, default)
  local value = settings.get(path, nil)
  if value == nil or value == "" then
    return default
  end
  return value
end

local function as_int(value, default)
  if type(value) == "number" then
    return math.floor(value)
  end
  if type(value) == "string" and value ~= "" then
    local n = tonumber(value)
    if n then
      return math.floor(n)
    end
  end
  return default
end

local function clamp(n, lo, hi)
  if n < lo then
    return lo
  end
  if n > hi then
    return hi
  end
  return n
end

local function url_encode(text)
  return (tostring(text):gsub("([^%w%-%._~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function append_query(url, params)
  local pieces = {}
  for _, entry in ipairs(params) do
    pieces[#pieces + 1] = url_encode(entry[1]) .. "=" .. url_encode(entry[2])
  end
  return url .. "?" .. table.concat(pieces, "&")
end

local function resolve_provider()
  return env(PROVIDER_ENV) or setting("web_search.provider", PROVIDER_DEFAULT)
end

local function resolve_timeout_ms()
  return as_int(env(TIMEOUT_ENV) or setting("web_search.timeout_ms", TIMEOUT_DEFAULT), TIMEOUT_DEFAULT)
end

local function resolve_max_bytes()
  return as_int(
    env(MAX_BYTES_ENV) or setting("web_search.max_response_bytes", MAX_BYTES_DEFAULT),
    MAX_BYTES_DEFAULT
  )
end

local function brave_api_key()
  return env_any(BRAVE_API_KEY_ENVS) or setting("web_search.brave.api_key", nil)
end

local function brave_base_url()
  return env(BRAVE_BASE_URL_ENV) or setting("web_search.brave.base_url", BRAVE_BASE_URL_DEFAULT)
end

local function error_message(body, fallback)
  local parsed = prelude.safe_json_decode(body, nil)
  if type(parsed) == "table" then
    if type(parsed.error) == "table" then
      if type(parsed.error.detail) == "string" and parsed.error.detail ~= "" then
        return parsed.error.detail
      end
      if type(parsed.error.message) == "string" and parsed.error.message ~= "" then
        return parsed.error.message
      end
      if type(parsed.error.code) == "string" and parsed.error.code ~= "" then
        return parsed.error.code
      end
    end
    if type(parsed.message) == "string" and parsed.message ~= "" then
      return parsed.message
    end
  end
  if type(body) == "string" and body ~= "" then
    local one_line = prelude.trim((body:gsub("%s+", " ")))
    if one_line ~= "" then
      return one_line
    end
  end
  return fallback
end

local function first_snippet(item)
  if type(item.description) == "string" and item.description ~= "" then
    return item.description
  end
  if type(item.extra_snippets) == "table" then
    for _, snippet in ipairs(item.extra_snippets) do
      if type(snippet) == "string" and snippet ~= "" then
        return snippet
      end
    end
  end
  return nil
end

local function format_results(results)
  if #results == 0 then
    return "No web results found."
  end
  local lines = {}
  for i, item in ipairs(results) do
    lines[#lines + 1] = string.format("%d. %s", i, item.title or item.url or "(untitled)")
    if item.url and item.url ~= "" then
      lines[#lines + 1] = "   " .. item.url
    end
    if item.snippet and item.snippet ~= "" then
      lines[#lines + 1] = "   " .. item.snippet
    end
  end
  return table.concat(lines, "\n")
end

local function brave_search(query, limit)
  local api_key = brave_api_key()
  local url, status, body, parsed, web_results
  local normalized = {}

  if not api_key or api_key == "" then
    return nil, "BRAVE_SEARCH_API_KEY is not set"
  end

  url = append_query(brave_base_url(), {
    { "q", query },
    { "count", tostring(limit) },
  })

  status, body = psi.http_request({
    url = url,
    method = "GET",
    headers = {
      "Accept: application/json",
      "X-Subscription-Token: " .. api_key,
    },
    timeout_ms = resolve_timeout_ms(),
    max_response_bytes = resolve_max_bytes(),
  })

  if not status then
    return nil, "web search request failed: " .. tostring(body or "unknown error")
  end
  if status < 200 or status >= 300 then
    return nil, ("web search request failed (%d): %s"):format(
      status,
      error_message(body, "unexpected response")
    )
  end

  parsed = prelude.safe_json_decode(body, nil)
  if type(parsed) ~= "table" then
    return nil, "web search returned invalid JSON"
  end

  web_results = parsed.web and parsed.web.results or {}
  if type(web_results) ~= "table" then
    web_results = {}
  end

  for _, item in ipairs(web_results) do
    normalized[#normalized + 1] = {
      title = type(item.title) == "string" and item.title or nil,
      url = type(item.url) == "string" and item.url or nil,
      snippet = first_snippet(item),
      age = type(item.age) == "string" and item.age or nil,
    }
  end

  return {
    provider = "brave",
    query = query,
    count = #normalized,
    results = normalized,
    output = format_results(normalized),
    request_url = url,
  }
end

function M.search(input)
  local query = type(input) == "table" and input.query or nil
  local limit = clamp(as_int(type(input) == "table" and input.limit or nil, LIMIT_DEFAULT), 1, LIMIT_MAX)
  local provider = resolve_provider()

  if type(query) ~= "string" or query == "" then
    return nil, "missing string field: query"
  end

  if provider == "brave" then
    return brave_search(query, limit)
  end
  return nil, "unsupported web search provider: " .. tostring(provider)
end

return M
