-- psi.mcp: minimal JSON-RPC MCP client over Streamable HTTP.
--
-- The C host owns only the generic asynchronous HTTP boundary. Protocol
-- lifecycle, capability negotiation, sessions, SSE parsing, discovery, and
-- tool registration stay here in Lua. This module intentionally does not
-- implement MCP over stdio: PSI_ENABLE_MCP gates low-level process primitives,
-- not a bundled stdio client transport.

local credential = require("psi.credential")
local prelude = require("psi.prelude")
local records = require("psi.records")
local registry = require("psi.tool_registry")
local sched = require("psi.sched")

local M = {}

local Client = {}
Client.__index = Client

local LATEST_PROTOCOL_VERSION = "2025-11-25"
local SUPPORTED_PROTOCOL_VERSIONS = {
  ["2025-11-25"] = true,
  ["2025-06-18"] = true,
  ["2025-03-26"] = true,
}
local DEFAULT_TIMEOUT_MS = 30000
local CLOSE_TIMEOUT_MS = 1000
local MAX_TIMEOUT_MS = 2147483647
local MAX_LIST_PAGES = 100
local CURL_OPERATION_TIMEDOUT = 28

local RESERVED_HEADERS = {
  ["accept"] = true,
  ["content-length"] = true,
  ["content-type"] = true,
  ["mcp-protocol-version"] = true,
  ["mcp-session-id"] = true,
  ["transfer-encoding"] = true,
}

local clients = {}
local registered_tools = {}
local bootstrap_report = {}
local shutdown_handler = nil

local function new_error(kind, message, fields)
  local err = fields or {}
  err.kind = kind
  err.message = tostring(message or kind)
  return err
end

local function encode(value)
  local ok, result = pcall(psi.json_encode, value)
  if not ok or type(result) ~= "string" then
    return nil, new_error("protocol", "failed to encode JSON-RPC message")
  end
  return result
end

local function decode(text)
  local ok, value, detail = pcall(psi.json_decode, text)
  if not ok or type(value) ~= "table" then
    return nil,
      new_error("protocol", "invalid JSON-RPC response", {
        detail = ok and detail or value,
      })
  end
  return value
end

local function media_type(value)
  if type(value) ~= "string" then
    return nil
  end
  return prelude.trim((value:match("^[^;]+") or value)):lower()
end

local function valid_session_id(value)
  if type(value) ~= "string" or value == "" then
    return false
  end
  for i = 1, #value do
    local byte = value:byte(i)
    if byte < 0x21 or byte > 0x7E then
      return false
    end
  end
  return true
end

local function poll_http(handle, timeout_ms)
  if sched.in_coroutine() then
    return sched.http_poll(handle, timeout_ms)
  end
  return psi.http_stream_poll(handle, timeout_ms)
end

local function new_sse_parser(on_message)
  return {
    buffer = "",
    data = {},
    on_message = on_message,
    failed = nil,
  }
end

local function dispatch_sse_event(parser)
  if #parser.data == 0 or parser.failed ~= nil then
    parser.data = {}
    return
  end
  local payload = table.concat(parser.data, "\n")
  parser.data = {}
  if payload == "" then
    return
  end
  local message, err = decode(payload)
  if message == nil then
    parser.failed = err
    return
  end
  local ok, callback_err = pcall(parser.on_message, message)
  if not ok then
    parser.failed = new_error("protocol", "failed to handle SSE message", {
      detail = callback_err,
    })
  end
end

local function feed_sse(parser, chunk, finish)
  parser.buffer = parser.buffer .. (chunk or "")
  while true do
    local newline = parser.buffer:find("\n", 1, true)
    if newline == nil then
      break
    end
    local line = parser.buffer:sub(1, newline - 1)
    parser.buffer = parser.buffer:sub(newline + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line == "" then
      dispatch_sse_event(parser)
    elseif line:sub(1, 1) ~= ":" then
      local field, value = line:match("^([^:]+):?(.*)$")
      if field == "data" then
        if value:sub(1, 1) == " " then
          value = value:sub(2)
        end
        parser.data[#parser.data + 1] = value
      end
    end
  end
  if finish then
    if parser.buffer ~= "" then
      local line = parser.buffer
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      if line:sub(1, 5) == "data:" then
        local value = line:sub(6)
        if value:sub(1, 1) == " " then
          value = value:sub(2)
        end
        parser.data[#parser.data + 1] = value
      end
    end
    parser.buffer = ""
    dispatch_sse_event(parser)
  end
end

local function resolve_headers(raw)
  if raw == nil then
    return {}
  end
  if type(raw) ~= "table" then
    return nil, new_error("config", "MCP headers must be an object")
  end
  local names = {}
  for name, value in pairs(raw) do
    if type(name) ~= "string" or name == "" or type(value) ~= "string" then
      return nil, new_error("config", "MCP header names and values must be strings")
    end
    local lower = name:lower()
    if RESERVED_HEADERS[lower] then
      return nil, new_error("config", "MCP header is reserved: " .. name)
    end
    if name:find("[\r\n:]") or value:find("[\r\n]") then
      return nil, new_error("config", "invalid MCP header: " .. name)
    end
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local value = credential.resolve(raw[name])
    if value == nil then
      return nil, new_error("config", "MCP header resolved to an empty value: " .. name)
    end
    out[#out + 1] = name .. ": " .. value
  end
  return out
end

local function request_headers(client, initialized)
  local out = {
    "Accept: application/json, text/event-stream",
    "Content-Type: application/json",
  }
  for _, header in ipairs(client.headers) do
    out[#out + 1] = header
  end
  if initialized then
    out[#out + 1] = "MCP-Protocol-Version: " .. client.protocol_version
    if client.session_id ~= nil then
      out[#out + 1] = "MCP-Session-Id: " .. client.session_id
    end
  end
  return out
end

function M.new_client(config)
  config = config or {}
  if type(config) ~= "table" then
    return nil, new_error("config", "MCP client configuration must be an object")
  end
  local transport = config.transport or "http"
  if transport ~= "http" and transport ~= "streamable-http" then
    return nil,
      new_error(
        "config",
        "unsupported MCP transport '"
          .. tostring(transport)
          .. "'; stdio client support is not implemented"
      )
  end
  if type(config.url) ~= "string" or not config.url:match("^https?://") then
    return nil, new_error("config", "MCP Streamable HTTP server requires an http(s) URL")
  end
  local timeout_ms = tonumber(config.timeout_ms or DEFAULT_TIMEOUT_MS)
  if
    timeout_ms == nil
    or timeout_ms < 1
    or timeout_ms > MAX_TIMEOUT_MS
    or timeout_ms ~= math.floor(timeout_ms)
  then
    return nil, new_error("config", "MCP timeout_ms must be an integer from 1 through 2147483647")
  end
  local headers, header_err = resolve_headers(config.headers)
  if headers == nil then
    return nil, header_err
  end
  local client = setmetatable({
    name = tostring(config.name or "mcp"),
    url = config.url,
    headers = headers,
    timeout_ms = timeout_ms,
    next_id = 1,
    initialized = false,
    closed = false,
    protocol_version = nil,
    session_id = nil,
    server_capabilities = {},
    server_info = nil,
    instructions = nil,
    notifications = {},
  }, Client)
  return client
end

function Client:_next_request_id()
  local id = self.next_id
  self.next_id = id + 1
  return id
end

function Client:_server_message(message)
  if message.jsonrpc ~= "2.0" then
    return
  end
  if type(message.method) == "string" and message.id == nil then
    self.notifications[#self.notifications + 1] = message
    return
  end
  if type(message.method) ~= "string" or message.id == nil or not self.initialized then
    return
  end
  local reply
  if message.method == "ping" then
    reply = { jsonrpc = "2.0", id = message.id, result = {} }
  else
    reply = {
      jsonrpc = "2.0",
      id = message.id,
      error = { code = -32601, message = "Method not found" },
    }
  end
  self:_send_oneway(reply, self.timeout_ms)
end

function Client:_perform(method, message, timeout_ms)
  if psi.http_stream_request_begin == nil then
    return nil, new_error("capability", "generic asynchronous HTTP requests are unavailable")
  end
  local body, encode_err = encode(message)
  if body == nil then
    return nil, encode_err
  end
  local initialized = self.initialized and method ~= "initialize"
  local handle, begin_err = psi.http_stream_request_begin(
    "POST",
    self.url,
    request_headers(self, initialized),
    body,
    timeout_ms or self.timeout_ms
  )
  if handle == nil then
    return nil, new_error("transport", begin_err or "failed to start MCP HTTP request")
  end

  local raw = {}
  local messages = {}
  local parser = new_sse_parser(function(inbound)
    messages[#messages + 1] = inbound
    self:_server_message(inbound)
  end)
  while true do
    local chunk, done = poll_http(handle, 50)
    if chunk ~= nil then
      raw[#raw + 1] = chunk
      feed_sse(parser, chunk, false)
    end
    if done then
      break
    end
  end
  local status, transport_error, response = psi.http_stream_finish(handle)
  response = type(response) == "table" and response or {}
  local transport_code = tonumber(response.transport_code) or 0
  if status == nil or status < 0 then
    if psi.is_aborted and psi.is_aborted() then
      return nil, new_error("aborted", "MCP request aborted")
    end
    if transport_code == CURL_OPERATION_TIMEDOUT then
      return nil,
        new_error("timeout", "MCP request timed out", {
          timeout_ms = timeout_ms or self.timeout_ms,
          transport_code = transport_code,
        })
    end
    return nil,
      new_error("transport", transport_error or "MCP HTTP transport failed", {
        transport_code = transport_code,
      })
  end

  local text = table.concat(raw)
  if status < 200 or status >= 300 then
    local detail = nil
    if text ~= "" then
      local parsed = decode(text)
      if parsed and type(parsed.error) == "table" then
        detail = parsed.error.message
      end
    end
    return nil,
      new_error("http", "MCP HTTP request failed with status " .. tostring(status), {
        status = status,
        detail = detail,
        body = text,
        response = response,
      })
  end

  return {
    status = status,
    body = text,
    response = response,
    messages = messages,
    parser = parser,
  }
end

function Client:_send_oneway(message, timeout_ms)
  local exchange, err = self:_perform(message.method or "response", message, timeout_ms)
  if exchange == nil then
    return nil, err
  end
  if exchange.status ~= 202 then
    return nil,
      new_error("protocol", "MCP notification/response was not accepted", {
        status = exchange.status,
      })
  end
  return true
end

function Client:_request_once(method, params, request_id)
  local message = {
    jsonrpc = "2.0",
    id = request_id,
    method = method,
  }
  if params ~= nil then
    message.params = params
  end
  local exchange, err = self:_perform(method, message, self.timeout_ms)
  if exchange == nil then
    return nil, nil, err
  end

  local content_type = media_type(exchange.response.content_type)
  local response_message = nil
  if content_type == "application/json" then
    if exchange.body == "" then
      return nil, exchange.response, new_error("protocol", "empty MCP JSON response")
    end
    response_message, err = decode(exchange.body)
    if response_message == nil then
      return nil, exchange.response, err
    end
  elseif content_type == "text/event-stream" then
    feed_sse(exchange.parser, "", true)
    if exchange.parser.failed ~= nil then
      return nil, exchange.response, exchange.parser.failed
    end
    for _, candidate in ipairs(exchange.messages) do
      if candidate.id == request_id and candidate.method == nil then
        response_message = candidate
        break
      end
    end
    if response_message == nil then
      return nil,
        exchange.response,
        new_error("protocol", "MCP SSE stream ended without the matching JSON-RPC response")
    end
  else
    return nil,
      exchange.response,
      new_error("protocol", "unsupported MCP response content type", {
        content_type = exchange.response.content_type,
      })
  end

  if response_message.jsonrpc ~= "2.0" or response_message.id ~= request_id then
    return nil, exchange.response, new_error("protocol", "invalid JSON-RPC response envelope")
  end
  if type(response_message.error) == "table" then
    return nil,
      exchange.response,
      new_error("rpc", response_message.error.message or "MCP JSON-RPC error", {
        code = response_message.error.code,
        data = response_message.error.data,
      })
  end
  if response_message.result == nil then
    return nil, exchange.response, new_error("protocol", "MCP JSON-RPC response has no result")
  end
  return response_message.result, exchange.response
end

function Client:initialize()
  if self.initialized then
    return true
  end
  if self.closed then
    return nil, new_error("closed", "MCP client is closed")
  end
  self.session_id = nil
  self.protocol_version = nil
  local request_id = self:_next_request_id()
  local result, response, err = self:_request_once("initialize", {
    protocolVersion = LATEST_PROTOCOL_VERSION,
    capabilities = {},
    clientInfo = {
      name = "psi",
      version = psi.version and psi.version() or "unknown",
    },
  }, request_id)
  if result == nil then
    return nil, err
  end
  if
    type(result) ~= "table"
    or type(result.protocolVersion) ~= "string"
    or type(result.capabilities) ~= "table"
    or type(result.serverInfo) ~= "table"
    or type(result.serverInfo.name) ~= "string"
    or type(result.serverInfo.version) ~= "string"
  then
    return nil, new_error("protocol", "MCP initialize returned an invalid result")
  end
  if not SUPPORTED_PROTOCOL_VERSIONS[result.protocolVersion] then
    return nil,
      new_error("protocol", "unsupported MCP protocol version", {
        protocol_version = result.protocolVersion,
      })
  end
  local session_id = response and response.mcp_session_id or nil
  if session_id ~= nil and not valid_session_id(session_id) then
    return nil, new_error("protocol", "invalid MCP-Session-Id response header")
  end
  self.protocol_version = result.protocolVersion
  self.session_id = session_id
  self.server_capabilities = type(result.capabilities) == "table" and result.capabilities or {}
  self.server_info = result.serverInfo
  self.instructions = result.instructions
  self.initialized = true

  local accepted, notify_err = self:_send_oneway({
    jsonrpc = "2.0",
    method = "notifications/initialized",
  }, self.timeout_ms)
  if not accepted then
    self.initialized = false
    self.session_id = nil
    self.protocol_version = nil
    return nil, notify_err
  end
  return true
end

function Client:request(method, params)
  if type(method) ~= "string" or method == "" then
    return nil, new_error("protocol", "MCP request method must be a non-empty string")
  end
  if self.closed then
    return nil, new_error("closed", "MCP client is closed")
  end
  if not self.initialized then
    local initialized, init_err = self:initialize()
    if not initialized then
      return nil, init_err
    end
  end
  if method:match("^tools/") and type(self.server_capabilities.tools) ~= "table" then
    return nil, new_error("capability", "MCP server did not negotiate tool support")
  end
  local result, _, err = self:_request_once(method, params, self:_next_request_id())
  if err and err.kind == "http" and err.status == 404 and self.session_id ~= nil then
    self.initialized = false
    self.session_id = nil
    self.protocol_version = nil
    local initialized, init_err = self:initialize()
    if not initialized then
      return nil, init_err
    end
    if method:match("^tools/") and type(self.server_capabilities.tools) ~= "table" then
      return nil, new_error("capability", "MCP server did not negotiate tool support")
    end
    result, _, err = self:_request_once(method, params, self:_next_request_id())
  end
  if err and err.kind == "timeout" then
    self:_send_oneway({
      jsonrpc = "2.0",
      method = "notifications/cancelled",
      params = { requestId = self.next_id - 1, reason = "request timed out" },
    }, math.min(self.timeout_ms, CLOSE_TIMEOUT_MS))
  end
  return result, err
end

function Client:notify(method, params)
  if type(method) ~= "string" or method == "" then
    return nil, new_error("protocol", "MCP notification method must be a non-empty string")
  end
  if self.closed then
    return nil, new_error("closed", "MCP client is closed")
  end
  if not self.initialized then
    local initialized, init_err = self:initialize()
    if not initialized then
      return nil, init_err
    end
  end
  local message = { jsonrpc = "2.0", method = method }
  if params ~= nil then
    message.params = params
  end
  return self:_send_oneway(message, self.timeout_ms)
end

function Client:list_tools()
  if self.closed then
    return nil, new_error("closed", "MCP client is closed")
  end
  if not self.initialized then
    local initialized, init_err = self:initialize()
    if not initialized then
      return nil, init_err
    end
  end
  if type(self.server_capabilities.tools) ~= "table" then
    return nil, new_error("capability", "MCP server did not negotiate tool support")
  end

  local tools = {}
  local cursor = nil
  local seen = {}
  for _ = 1, MAX_LIST_PAGES do
    local params = cursor and { cursor = cursor } or nil
    local result, err = self:request("tools/list", params)
    if result == nil then
      return nil, err
    end
    if type(result) ~= "table" or type(result.tools) ~= "table" then
      return nil, new_error("protocol", "MCP tools/list result has no tools array")
    end
    for _, tool in ipairs(result.tools) do
      if
        type(tool) ~= "table"
        or type(tool.name) ~= "string"
        or tool.name == ""
        or (tool.description ~= nil and type(tool.description) ~= "string")
        or type(tool.inputSchema) ~= "table"
      then
        return nil, new_error("protocol", "MCP tools/list returned an invalid tool")
      end
      tools[#tools + 1] = tool
    end
    cursor = result.nextCursor
    if cursor == nil then
      return tools
    end
    if type(cursor) ~= "string" or cursor == "" or seen[cursor] then
      return nil, new_error("protocol", "MCP tools/list returned an invalid cursor")
    end
    seen[cursor] = true
  end
  return nil, new_error("protocol", "MCP tools/list exceeded pagination limit")
end

function Client:call_tool(name, arguments)
  if type(name) ~= "string" or name == "" then
    return nil, new_error("protocol", "MCP tool name must be a non-empty string")
  end
  if arguments ~= nil and type(arguments) ~= "table" then
    return nil, new_error("protocol", "MCP tool arguments must be an object")
  end
  local result, err = self:request("tools/call", {
    name = name,
    arguments = arguments or {},
  })
  if result == nil then
    return nil, err
  end
  if
    type(result) ~= "table"
    or type(result.content) ~= "table"
    or (result.isError ~= nil and type(result.isError) ~= "boolean")
  then
    return nil, new_error("protocol", "MCP tools/call returned an invalid result")
  end
  return result
end

function Client:close()
  if self.closed then
    return true
  end
  local session_id = self.session_id
  local protocol_version = self.protocol_version
  self.closed = true
  self.initialized = false
  self.session_id = nil
  self.protocol_version = nil
  if session_id == nil or psi.http_stream_request_begin == nil then
    return true
  end

  local headers = {
    "Accept: application/json, text/event-stream",
    "MCP-Protocol-Version: " .. protocol_version,
    "MCP-Session-Id: " .. session_id,
  }
  for _, header in ipairs(self.headers) do
    headers[#headers + 1] = header
  end
  local handle, begin_err = psi.http_stream_request_begin(
    "DELETE",
    self.url,
    headers,
    "",
    math.min(self.timeout_ms, CLOSE_TIMEOUT_MS)
  )
  if handle == nil then
    return nil, new_error("transport", begin_err or "failed to close MCP HTTP session")
  end
  while true do
    local _, done = poll_http(handle, 50)
    if done then
      break
    end
  end
  local status, transport_error, response = psi.http_stream_finish(handle)
  response = type(response) == "table" and response or {}
  if status == nil or status < 0 then
    return nil,
      new_error("transport", transport_error or "failed to close MCP HTTP session", {
        transport_code = response.transport_code,
      })
  end
  if status == 405 or (status >= 200 and status < 300) then
    return true
  end
  return nil,
    new_error("http", "MCP session close failed with status " .. tostring(status), {
      status = status,
    })
end

local function safe_tool_name(prefix, remote_name)
  local name = (tostring(prefix) .. "_" .. tostring(remote_name)):gsub("[^%w_-]", "_")
  if #name <= 64 then
    return name
  end
  return name:sub(1, 47) .. "_" .. prelude.hash_hex(name):sub(1, 16)
end

local function tool_output(result)
  local parts = {}
  for _, block in ipairs(type(result.content) == "table" and result.content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    else
      local encoded = encode(block)
      if encoded ~= nil then
        parts[#parts + 1] = encoded
      end
    end
  end
  if #parts == 0 and result.structuredContent ~= nil then
    local encoded = encode(result.structuredContent)
    if encoded ~= nil then
      parts[1] = encoded
    end
  end
  return table.concat(parts, "\n")
end

local function register_discovered_tools(server_name, config, client, tools)
  local prefix = config.tool_prefix or server_name
  if type(prefix) ~= "string" or prefix == "" then
    return nil, new_error("config", "MCP tool_prefix must be a non-empty string")
  end
  local staged = {}
  local seen = {}
  for _, remote in ipairs(tools) do
    local local_name = safe_tool_name(prefix, remote.name)
    if seen[local_name] or (registry.find(local_name) and not registered_tools[local_name]) then
      return nil, new_error("config", "MCP tool name collision: " .. local_name)
    end
    seen[local_name] = true
    staged[#staged + 1] = { local_name = local_name, remote = remote }
  end

  for _, item in ipairs(staged) do
    local local_name = item.local_name
    local remote = item.remote
    local tool = records.new_tool(
      local_name,
      remote.description or ("MCP tool " .. remote.name .. " from " .. server_name),
      "Call MCP tool " .. remote.name .. " on server " .. server_name,
      {},
      remote.inputSchema,
      function(input)
        local result, err = client:call_tool(remote.name, input)
        if result == nil then
          return records.tool_failure(local_name, err.message)
        end
        if type(result.content) ~= "table" then
          return records.tool_failure(local_name, "MCP tools/call result has no content array")
        end
        local output = tool_output(result)
        return records.new_tool_result(
          not result.isError,
          local_name,
          result.isError and (output ~= "" and output or "MCP tool reported an error") or nil,
          {
            output = output,
            content = result.content,
            structuredContent = result.structuredContent,
            mcp_server = server_name,
            mcp_tool = remote.name,
          }
        )
      end,
      { execution_mode = "sequential" }
    )
    registry.register(tool)
    registered_tools[local_name] = tool
  end
  return true
end

local function install_shutdown_handler()
  if not psi.events or not psi.events.on then
    return
  end
  if shutdown_handler and psi.events.off then
    psi.events.off("session-shutdown", shutdown_handler)
  end
  shutdown_handler = function()
    M.close_all()
  end
  psi.events.on("session-shutdown", shutdown_handler)
end

local function server_configs()
  local configured = psi.settings and psi.settings.get and psi.settings.get("mcp.servers", {}) or {}
  if type(configured) ~= "table" then
    return nil, new_error("config", "mcp.servers must be an object")
  end
  local names = {}
  for name in pairs(configured) do
    if type(name) ~= "string" or name == "" then
      return nil, new_error("config", "mcp.servers keys must be non-empty strings")
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return configured, names
end

function M.bootstrap()
  if next(clients) ~= nil or next(registered_tools) ~= nil then
    M.close_all({ unregister = true })
  end
  bootstrap_report = {}
  install_shutdown_handler()
  local configured, names_or_err = server_configs()
  if configured == nil then
    bootstrap_report.config = names_or_err
    io.stderr:write("psi: MCP configuration failed: " .. names_or_err.message .. "\n")
    return bootstrap_report
  end
  for _, name in ipairs(names_or_err) do
    local config = configured[name]
    if type(config) ~= "table" then
      local err = new_error("config", "MCP server configuration must be an object")
      bootstrap_report[name] = { ok = false, error = err }
      io.stderr:write("psi: MCP server " .. name .. " failed: " .. err.message .. "\n")
    elseif config.enabled ~= false then
      local copy = {}
      for key, value in pairs(config) do
        copy[key] = value
      end
      copy.name = name
      local client, err = M.new_client(copy)
      if client ~= nil then
        local initialized
        initialized, err = client:initialize()
        if initialized then
          local tools
          tools, err = client:list_tools()
          if tools ~= nil then
            local registered
            registered, err = register_discovered_tools(name, config, client, tools)
            if registered then
              clients[name] = client
              bootstrap_report[name] = { ok = true, tools = #tools }
            end
          end
        end
      end
      if err ~= nil then
        bootstrap_report[name] = { ok = false, error = err }
        if client ~= nil then
          client:close()
        end
        io.stderr:write("psi: MCP server " .. name .. " failed: " .. err.message .. "\n")
      end
    end
  end
  return bootstrap_report
end

function M.close_all(opts)
  opts = opts or {}
  local names = {}
  for name in pairs(clients) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    pcall(clients[name].close, clients[name])
  end
  clients = {}
  if opts.unregister ~= false then
    for name, tool in pairs(registered_tools) do
      if registry.find(name) == tool then
        registry.unregister(name)
      end
    end
    registered_tools = {}
  end
end

function M.reload()
  M.close_all({ unregister = true })
  return M.bootstrap()
end

function M.clients()
  local out = {}
  for name, client in pairs(clients) do
    out[name] = client
  end
  return out
end

function M.status()
  return bootstrap_report
end

M.Client = Client
M.PROTOCOL_VERSION = LATEST_PROTOCOL_VERSION
M.SUPPORTED_PROTOCOL_VERSIONS = SUPPORTED_PROTOCOL_VERSIONS

return M
