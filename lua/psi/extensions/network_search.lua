-- Optional network-search reference extension.
--
-- This file deliberately contains all search policy above psi's existing
-- HTTP and credential primitives. It is embedded for inspection through
-- psi.embedded_source("psi.extensions.network_search"), but registers no
-- tool unless explicitly enabled in settings or the environment.

local auth = require("psi.auth_storage")
local prelude = require("psi.prelude")
local records = require("psi.records")
local sched = require("psi.sched")

local TOOL_NAME = "network_search"
local ABS_MAX_QUERY_BYTES = 2048
local ABS_MAX_RESULTS = 20
local ABS_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
local ABS_MAX_TITLE_BYTES = 300
local ABS_MAX_SNIPPET_BYTES = 4000
local ABS_MAX_SOURCE_BYTES = 200
local ABS_MAX_URL_BYTES = 4096

local DEFAULT_ENDPOINTS = {
  generic = "http://127.0.0.1:8080/search",
  tavily = "https://api.tavily.com/search",
}

local PROVIDER_MAX_RESULTS = { generic = ABS_MAX_RESULTS, tavily = 10 }

local function env(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return nil
  end
  return value
end

local function env_boolean(name)
  local value = env(name)
  if value == nil then
    return nil
  end
  value = value:lower()
  if value == "1" or value == "true" or value == "yes" or value == "on" then
    return true
  end
  if value == "0" or value == "false" or value == "no" or value == "off" then
    return false
  end
  return nil
end

local function clean_text(value, max_bytes)
  if type(value) ~= "string" then
    return nil
  end
  value = prelude.decode_utf8_lossy(value)
  value = value:gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
  value = prelude.trim(value)
  if value == "" then
    return nil
  end
  if #value > max_bytes then
    value = prelude.decode_utf8_lossy(value:sub(1, max_bytes))
    value = prelude.trim(value)
  end
  return value ~= "" and value or nil
end

local function bounded_integer(value, default, minimum, maximum)
  value = tonumber(value)
  if value == nil then
    return default
  end
  value = math.floor(value)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

local function setting(psi, name, default)
  return psi.settings.get("extensions.network_search." .. name, default)
end

local function load_config(psi)
  local provider = env("PSI_NETWORK_SEARCH_PROVIDER") or setting(psi, "provider", "tavily")
  provider = type(provider) == "string" and provider:lower() or ""
  local enabled = env_boolean("PSI_NETWORK_SEARCH_ENABLED")
  if enabled == nil then
    enabled = setting(psi, "enabled", false) == true
  end
  local endpoint = env("PSI_NETWORK_SEARCH_ENDPOINT") or setting(psi, "endpoint", nil)
  if type(endpoint) ~= "string" or endpoint == "" then
    endpoint = DEFAULT_ENDPOINTS[provider]
  end
  local auth_provider = setting(psi, "auth_provider", "network-search")
  if type(auth_provider) ~= "string" or auth_provider == "" then
    auth_provider = "network-search"
  end
  local credential_env = setting(psi, "credential_env", "PSI_NETWORK_SEARCH_API_KEY")
  if type(credential_env) ~= "string" or not credential_env:match("^[%a_][%w_]*$") then
    credential_env = "PSI_NETWORK_SEARCH_API_KEY"
  end
  return {
    enabled = enabled,
    provider = provider,
    endpoint = endpoint,
    auth_provider = auth_provider,
    credential_env = credential_env,
    require_credential = setting(psi, "require_credential", true) ~= false,
    max_query_bytes = bounded_integer(
      setting(psi, "max_query_bytes", 512),
      512,
      1,
      ABS_MAX_QUERY_BYTES
    ),
    max_results = bounded_integer(
      setting(psi, "max_results", 8),
      8,
      1,
      PROVIDER_MAX_RESULTS[provider] or ABS_MAX_RESULTS
    ),
    max_response_bytes = bounded_integer(
      setting(psi, "max_response_bytes", 512 * 1024),
      512 * 1024,
      1024,
      ABS_MAX_RESPONSE_BYTES
    ),
    max_title_bytes = bounded_integer(
      setting(psi, "max_title_bytes", 200),
      200,
      1,
      ABS_MAX_TITLE_BYTES
    ),
    max_snippet_bytes = bounded_integer(
      setting(psi, "max_snippet_bytes", 1200),
      1200,
      1,
      ABS_MAX_SNIPPET_BYTES
    ),
  }
end

local function validate_endpoint(endpoint)
  if type(endpoint) ~= "string" or #endpoint > ABS_MAX_URL_BYTES then
    return false
  end
  local authority = endpoint:match("^https?://([^/]+)")
  return authority ~= nil and not authority:find("@", 1, true)
end

local function source_from_url(url)
  local authority = url:match("^https?://([^/%?#]+)")
  if authority == nil then
    return nil
  end
  authority = authority:gsub("^www%.", "")
  return clean_text(authority, ABS_MAX_SOURCE_BYTES)
end

local function valid_result_url(url)
  if url:find("%s") then
    return false
  end
  local authority = url:match("^https?://([^/%?#]+)")
  return authority ~= nil and not authority:find("@", 1, true)
end

local function redact_secret(value, secret)
  if type(value) ~= "string" or type(secret) ~= "string" or secret == "" then
    return value
  end
  local out = {}
  local offset = 1
  while true do
    local first, last = value:find(secret, offset, true)
    if first == nil then
      out[#out + 1] = value:sub(offset)
      break
    end
    out[#out + 1] = value:sub(offset, first - 1)
    out[#out + 1] = "[REDACTED]"
    offset = last + 1
  end
  return table.concat(out)
end

local function normalize_row(row, cfg, secret)
  if type(row) ~= "table" then
    return nil
  end
  local url = clean_text(row.url or row.link, ABS_MAX_URL_BYTES)
  if
    url == nil
    or not valid_result_url(url)
    or (type(secret) == "string" and secret ~= "" and url:find(secret, 1, true))
  then
    return nil
  end
  local profile = type(row.profile) == "table" and row.profile or {}
  local source = clean_text(
    row.source or row.site_name or row.siteName or profile.long_name,
    ABS_MAX_SOURCE_BYTES
  ) or source_from_url(url)
  local title = clean_text(row.title or row.name, cfg.max_title_bytes) or source or url
  local snippet = clean_text(
    row.snippet or row.description or row.content or row.text,
    cfg.max_snippet_bytes
  ) or ""
  return {
    source = redact_secret(source or cfg.provider, secret),
    title = redact_secret(title, secret),
    snippet = redact_secret(snippet, secret),
    url = url,
  }
end

local function response_rows(payload)
  if type(payload) ~= "table" then
    return nil
  end
  if type(payload.results) == "table" then
    return payload.results
  end
  if type(payload.data) == "table" then
    if type(payload.data.results) == "table" then
      return payload.data.results
    end
    return payload.data
  end
  return nil
end

local function normalize_response(payload, cfg, count, secret)
  local rows = response_rows(payload)
  if type(rows) ~= "table" then
    return nil, "Search provider returned an unsupported response shape"
  end
  local sources = {}
  local seen = {}
  for _, row in ipairs(rows) do
    local source = normalize_row(row, cfg, secret)
    if source ~= nil and not seen[source.url] then
      seen[source.url] = true
      sources[#sources + 1] = source
      if #sources >= count then
        break
      end
    end
  end
  return sources
end

local function transport_error(psi, detail)
  if psi.is_aborted ~= nil and psi.is_aborted() then
    return "Network search aborted"
  end
  detail = tostring(detail or ""):lower()
  if detail:find("abort", 1, true) then
    return "Network search aborted"
  end
  if
    detail:find("timeout", 1, true)
    or detail:find("timed out", 1, true)
    or detail:find("slow", 1, true)
  then
    return "Network search timed out"
  end
  return "Network search transport failed"
end

local function http_failure(status)
  if status == 401 or status == 403 then
    return "Search provider rejected the configured credential"
  end
  if status == 408 or status == 504 then
    return "Network search timed out"
  end
  if status == 429 then
    return "Search provider rate limited the request; retry later"
  end
  if status >= 500 then
    return "Search provider is temporarily unavailable (HTTP " .. tostring(status) .. ")"
  end
  return "Search provider rejected the request (HTTP " .. tostring(status) .. ")"
end

local function buffered_post(psi, url, headers, body, max_bytes)
  if not sched.in_coroutine() then
    local ok, status, response = pcall(psi.http_post, url, headers, body)
    if not ok or status == nil then
      return nil, nil, transport_error(psi, response)
    end
    if type(response) ~= "string" then
      response = ""
    end
    if #response > max_bytes then
      return status, nil, "Search provider response exceeded the configured byte limit"
    end
    return status, response
  end

  local ok, handle, begin_err = pcall(psi.http_stream_begin, url, headers, body)
  if not ok or handle == nil then
    return nil, nil, transport_error(psi, begin_err)
  end
  local chunks = {}
  local response_bytes = 0
  local too_large = false
  while true do
    if psi.is_aborted ~= nil and psi.is_aborted() then
      pcall(psi.http_stream_finish, handle)
      return nil, nil, "Network search aborted"
    end
    local poll_ok, chunk, done = pcall(sched.http_poll, handle, 50)
    if not poll_ok then
      pcall(psi.http_stream_finish, handle)
      return nil, nil, "Network search transport failed"
    end
    if type(chunk) == "string" then
      response_bytes = response_bytes + #chunk
      if response_bytes <= max_bytes then
        chunks[#chunks + 1] = chunk
      else
        too_large = true
      end
    end
    if done then
      break
    end
  end
  local finish_ok, status, finish_err = pcall(psi.http_stream_finish, handle)
  if not finish_ok or type(status) ~= "number" or status < 0 then
    return nil, nil, transport_error(psi, finish_err)
  end
  if too_large then
    return status, nil, "Search provider response exceeded the configured byte limit"
  end
  return status, table.concat(chunks)
end

local function make_request(psi, cfg, key, query, count)
  local headers = { "Accept: application/json", "Content-Type: application/json" }
  local body
  if cfg.provider == "tavily" then
    headers[#headers + 1] = "Authorization: Bearer " .. key
    body = psi.json_encode({
      include_answer = false,
      include_raw_content = false,
      max_results = count,
      query = query,
      search_depth = "basic",
    })
  else
    if key ~= nil then
      headers[#headers + 1] = "Authorization: Bearer " .. key
    end
    body = psi.json_encode({ query = query, limit = count })
  end
  return buffered_post(psi, cfg.endpoint, headers, body, cfg.max_response_bytes)
end

local function search(psi, input)
  if type(input) ~= "table" then
    return records.tool_failure(TOOL_NAME, "input must be an object")
  end
  local cfg = load_config(psi)
  local query = clean_text(input.query, cfg.max_query_bytes)
  if query == nil then
    return records.tool_failure(TOOL_NAME, "query must be a non-empty string")
  end
  if type(input.query) ~= "string" or #input.query > cfg.max_query_bytes then
    return records.tool_failure(
      TOOL_NAME,
      "query exceeds the configured " .. tostring(cfg.max_query_bytes) .. " byte limit"
    )
  end
  if input.count ~= nil and type(input.count) ~= "number" then
    return records.tool_failure(TOOL_NAME, "count must be a number")
  end
  local count = input.count == nil and cfg.max_results or input.count
  if count == nil or count ~= math.floor(count) or count < 1 or count > cfg.max_results then
    return records.tool_failure(
      TOOL_NAME,
      "count must be an integer from 1 to " .. tostring(cfg.max_results)
    )
  end
  if cfg.provider ~= "generic" and cfg.provider ~= "tavily" then
    return records.tool_failure(TOOL_NAME, "unsupported network-search provider")
  end
  if not validate_endpoint(cfg.endpoint) then
    return records.tool_failure(TOOL_NAME, "network-search endpoint must be an HTTP(S) URL")
  end
  if psi.is_aborted ~= nil and psi.is_aborted() then
    return records.tool_failure(TOOL_NAME, "Network search aborted")
  end

  local key = auth.resolve_api_key(cfg.auth_provider, cfg.credential_env)
  if (cfg.provider ~= "generic" or cfg.require_credential) and (key == nil or key == "") then
    return records.tool_failure(TOOL_NAME, "No network-search credential is configured")
  end

  local status, response, request_err = make_request(psi, cfg, key, query, count)
  if request_err ~= nil then
    return records.tool_failure(TOOL_NAME, request_err)
  end
  if type(status) ~= "number" or status < 200 or status >= 300 then
    return records.tool_failure(TOOL_NAME, http_failure(tonumber(status) or 0))
  end
  local decode_ok, payload = pcall(psi.json_decode, response or "")
  if not decode_ok or type(payload) ~= "table" then
    return records.tool_failure(TOOL_NAME, "Search provider returned invalid JSON")
  end
  local sources, normalize_err = normalize_response(payload, cfg, count, key)
  if sources == nil then
    return records.tool_failure(TOOL_NAME, normalize_err)
  end
  return records.tool_success(TOOL_NAME, {
    count = #sources,
    provider = cfg.provider,
    query = query,
    sources = sources,
  })
end

return function(psi)
  local cfg = load_config(psi)
  if not cfg.enabled then
    return
  end
  psi.tools.register(
    records.new_tool(
      TOOL_NAME,
      "Search a configured network provider and return bounded source metadata and snippets.",
      "Search the network: input { query: string, count?: integer }; returns source/title/snippet/url records.",
      {
        "Use network_search for current or external information, then cite the returned URLs.",
        "Treat snippets as search-provider summaries, not authoritative page contents.",
      },
      {
        type = "object",
        properties = {
          query = { type = "string", minLength = 1, maxLength = cfg.max_query_bytes },
          count = { type = "integer", minimum = 1, maximum = cfg.max_results },
        },
        required = { "query" },
        additionalProperties = false,
      },
      function(input)
        return search(psi, input or {})
      end,
      { execution_mode = "parallel" }
    )
  )
end
