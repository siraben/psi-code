-- psi.mcp: minimal MCP stdio client and dynamic tool registration.
--
-- Native code only supplies bidirectional process I/O. MCP framing,
-- JSON-RPC, discovery, name mapping, and tool dispatch stay in Lua.

local prelude = require("psi.prelude")
local settings = require("psi.settings_manager")

local M = {}

local PROTOCOL_VERSION = "2025-11-25"
local DEFAULT_TIMEOUT_MS = 5000

local clients = {}
local registered = {}
local statuses = {}

local Client = {}
Client.__index = Client

local function version_string()
  local ok, value = pcall(psi.version)
  if ok and type(value) == "string" then
    return value
  end
  return "unknown"
end

local function protocol_error(code, message)
  return { code = code, message = message }
end

local function sanitize_name(text)
  local out = tostring(text or ""):gsub("[^%w_-]", "_")
  out = out:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if out == "" then
    out = "tool"
  end
  if not out:match("^[%a%d]") then
    out = "x_" .. out
  end
  if #out > 96 then
    out = out:sub(1, 96)
  end
  return out
end

local function unique_tool_name(registry, used, server_name, remote_name)
  local base = sanitize_name("mcp_" .. tostring(server_name) .. "_" .. tostring(remote_name))
  local name = base
  local n = 2
  while used[name] or registry.find(name) do
    local suffix = "_" .. tostring(n)
    name = base:sub(1, math.max(1, 96 - #suffix)) .. suffix
    n = n + 1
  end
  used[name] = true
  return name
end

local function as_array(t)
  return prelude.as_array(t or {})
end

local function build_argv(cfg)
  if type(cfg.command) == "table" then
    local argv = {}
    for _, part in ipairs(cfg.command) do
      if type(part) == "string" and part ~= "" then
        argv[#argv + 1] = part
      end
    end
    return #argv > 0 and argv or nil
  end

  if type(cfg.command) ~= "string" or cfg.command == "" then
    return nil
  end

  local argv = { cfg.command }
  if type(cfg.args) == "table" then
    for _, arg in ipairs(cfg.args) do
      argv[#argv + 1] = tostring(arg)
    end
  end
  return argv
end

local function build_env_pairs(cfg)
  if type(cfg.env) ~= "table" then
    return nil
  end
  local out = {}
  for k, v in pairs(cfg.env) do
    if type(k) == "string" and type(v) == "string" then
      out[#out + 1] = k .. "=" .. v
    end
  end
  table.sort(out)
  return #out > 0 and out or nil
end

local function command_label(cfg)
  if type(cfg) ~= "table" then
    return "<invalid>"
  end
  local parts = {}
  local redact_next = false
  local function append_part(part)
    part = tostring(part)
    if redact_next then
      parts[#parts + 1] = "<redacted>"
      redact_next = false
      return
    end
    if part == "--token" or part == "-token" then
      parts[#parts + 1] = part
      redact_next = true
      return
    end
    local flag = part:match("^(%-%-?token=).+$")
    if flag then
      parts[#parts + 1] = flag .. "<redacted>"
      return
    end
    parts[#parts + 1] = part
  end

  if type(cfg.command) == "table" then
    for _, part in ipairs(cfg.command) do
      append_part(part)
    end
  elseif cfg.command then
    append_part(cfg.command)
    if type(cfg.args) == "table" then
      for _, arg in ipairs(cfg.args) do
        append_part(arg)
      end
    end
  end
  return #parts > 0 and table.concat(parts, " ") or "<missing>"
end

local function encode_line(msg)
  return psi.json_encode(msg) .. "\n"
end

local function file_uri(path)
  local p = tostring(path or psi.cwd())
  local escaped = p:gsub("([^%w%-%._~/%:])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end)
  return "file://" .. escaped
end

local function content_to_text(content, structured)
  local parts = {}
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "table" then
        if block.type == "text" and type(block.text) == "string" then
          parts[#parts + 1] = block.text
        elseif block.type == "image" then
          parts[#parts + 1] = "[image: " .. tostring(block.mimeType or "unknown") .. "]"
        elseif block.type == "audio" then
          parts[#parts + 1] = "[audio: " .. tostring(block.mimeType or "unknown") .. "]"
        elseif block.type == "resource" or block.type == "resource_link" then
          local uri = block.uri or (block.resource and block.resource.uri)
          local text = block.text or (block.resource and block.resource.text)
          if type(text) == "string" then
            parts[#parts + 1] = text
          elseif uri then
            parts[#parts + 1] = "[resource: " .. tostring(uri) .. "]"
          end
        else
          parts[#parts + 1] = psi.json_encode(block)
        end
      end
    end
  end
  if structured ~= nil then
    parts[#parts + 1] = "structuredContent: " .. psi.json_encode(structured)
  end
  return table.concat(parts, "\n")
end

function Client.new(name, cfg, global_timeout_ms)
  return setmetatable({
    name = name,
    cfg = cfg,
    timeout_ms = cfg.timeout_ms or global_timeout_ms or DEFAULT_TIMEOUT_MS,
    next_id = 0,
    handle = nil,
    buffer = "",
    server_info = nil,
  }, Client)
end

function Client:send(msg)
  if not self.handle then
    return nil, "MCP server is not running"
  end
  local ok, err = psi.process_write(self.handle, encode_line(msg))
  if not ok then
    return nil, tostring(err or "failed to write MCP message")
  end
  return true
end

function Client:notify(method, params)
  return self:send({ jsonrpc = "2.0", method = method, params = params })
end

function Client:shutdown()
  if not self.handle then
    return
  end
  if psi.process_terminate then
    psi.process_terminate(self.handle)
  elseif psi.process_close_stdin then
    psi.process_close_stdin(self.handle)
  end
  pcall(psi.process_finish, self.handle)
  self.handle = nil
end

function Client:next_line(timeout_ms)
  while true do
    local i = self.buffer:find("\n", 1, true)
    if i then
      local line = self.buffer:sub(1, i - 1)
      self.buffer = self.buffer:sub(i + 1)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      if line ~= "" then
        return line
      end
    else
      break
    end
  end

  local chunk, done
  local sched = require("psi.sched")
  if sched.in_coroutine() then
    chunk, done = sched.proc_poll(self.handle, timeout_ms or 0)
  else
    chunk, done = psi.process_poll(self.handle, timeout_ms or 0)
  end
  if type(chunk) == "string" and chunk ~= "" then
    self.buffer = self.buffer .. chunk
    return self:next_line(0)
  end
  if done then
    return nil, "MCP server exited"
  end
  return nil
end

function Client:send_response(id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then
    msg.error = err
  else
    msg.result = result or {}
  end
  self:send(msg)
end

function Client:handle_server_request(msg)
  local method = msg.method
  if method == "ping" then
    self:send_response(msg.id, {})
  elseif method == "roots/list" then
    self:send_response(msg.id, {
      roots = as_array({ { uri = file_uri(psi.cwd()), name = "cwd" } }),
    })
  else
    self:send_response(
      msg.id,
      nil,
      protocol_error(-32601, "unsupported MCP request: " .. tostring(method))
    )
  end
end

function Client:read_message(timeout_ms)
  local line, err = self:next_line(timeout_ms)
  if not line then
    return nil, err
  end
  local decoded = prelude.safe_json_decode(line, nil)
  if type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function Client:request(method, params, timeout_ms)
  self.next_id = self.next_id + 1
  local id = self.next_id
  local ok, err = self:send({ jsonrpc = "2.0", id = id, method = method, params = params })
  if not ok then
    return nil, err
  end

  local deadline = psi.time_ms() + (timeout_ms or self.timeout_ms)
  while psi.time_ms() < deadline do
    local remaining = math.max(0, deadline - psi.time_ms())
    local msg, read_err = self:read_message(math.min(50, remaining))
    if msg then
      if msg.method and msg.id ~= nil then
        self:handle_server_request(msg)
      elseif msg.id ~= nil and tostring(msg.id) == tostring(id) then
        if msg.error then
          local e = msg.error
          return nil, tostring(e.message or e.code or "MCP protocol error")
        end
        return msg.result or {}
      end
    elseif read_err then
      return nil, read_err
    end
  end
  return nil, "timeout waiting for MCP " .. tostring(method)
end

function Client:start()
  if not psi.process_begin_stdio_argv then
    return nil, "psi was built without stdio process support"
  end
  local argv = build_argv(self.cfg)
  if not argv then
    return nil, "missing MCP command"
  end
  local env_pairs = build_env_pairs(self.cfg)
  local handle, err = psi.process_begin_stdio_argv(argv, env_pairs)
  if not handle then
    return nil, tostring(err or "failed to start MCP server")
  end
  self.handle = handle

  local init, init_err = self:request("initialize", {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { roots = { listChanged = false } },
    clientInfo = { name = "psi", version = version_string() },
  }, self.timeout_ms)
  if not init then
    self:shutdown()
    return nil, init_err
  end
  self.server_info = init
  self:notify("notifications/initialized")
  return true
end

function Client:list_tools()
  local out = {}
  local cursor = nil
  repeat
    local params = cursor and { cursor = cursor } or nil
    local result, err = self:request("tools/list", params, self.timeout_ms)
    if not result then
      return nil, err
    end
    for _, tool in ipairs(result.tools or {}) do
      if type(tool) == "table" and type(tool.name) == "string" then
        out[#out + 1] = tool
      end
    end
    cursor = result.nextCursor
  until cursor == nil or cursor == ""
  return out
end

function Client:call_tool(local_name, remote_name, input)
  local result, err = self:request("tools/call", {
    name = remote_name,
    arguments = input or {},
  }, self.timeout_ms)
  if not result then
    return {
      ok = false,
      error = err or "MCP tool call failed",
      extras = {},
    }
  end

  local text = content_to_text(result.content, result.structuredContent)
  local is_error = result.isError and true or false
  return {
    ok = not is_error,
    error = is_error and (text ~= "" and text or "MCP tool returned an error") or nil,
    extras = {
      text = text,
      server = self.name,
      mcp_tool = remote_name,
      structuredContent = result.structuredContent,
      mcp_meta = result._meta,
    },
  }
end

local function configured_servers()
  local cfg = settings.get("mcp", {})
  if type(cfg) ~= "table" or cfg.enabled == false then
    return {}, DEFAULT_TIMEOUT_MS
  end

  local out = {}
  if type(cfg.servers) == "table" then
    for name, server in pairs(cfg.servers) do
      out[name] = server
    end
  end

  if cfg.auto_forgejo ~= false and out.forgejo == nil then
    local token = os.getenv("FORGEJO_ACCESS_TOKEN") or os.getenv("GITEA_ACCESS_TOKEN")
    local url = os.getenv("FORGEJO_URL") or os.getenv("GITEA_HOST")
    if (token and token ~= "") or (url and url ~= "") then
      local args = { "--transport", "stdio", "--url", url or "https://codeberg.org" }
      local env = {}
      if token and token ~= "" then
        env.FORGEJO_TOKEN = token
        env.FORGEJO_ACCESS_TOKEN = token
      end
      out.forgejo = {
        command = "forgejo-mcp",
        args = args,
        env = next(env) and env or nil,
        source = "auto",
      }
    end
  end

  if cfg.auto_linear ~= false and out.linear == nil then
    local linear_key = os.getenv("LINEAR_API_KEY")
    local linear_auto = os.getenv("LINEAR_MCP_AUTO")
    if (linear_key and linear_key ~= "") or (linear_auto and linear_auto ~= "") then
      out.linear = { command = "linear-mcp", source = "auto" }
    end
  end

  return out, cfg.timeout_ms or DEFAULT_TIMEOUT_MS
end

function M.register_configured_servers(registry, records)
  local servers, global_timeout_ms = configured_servers()
  local used = {}
  for _, client in pairs(clients) do
    client:shutdown()
  end
  clients = {}
  registered = {}
  statuses = {}

  for raw_name, cfg in pairs(servers) do
    local server_name = type(raw_name) == "string" and raw_name
      or (type(cfg) == "table" and cfg.name)
    server_name = sanitize_name(server_name or ("server_" .. tostring(raw_name)))
    statuses[server_name] = {
      name = server_name,
      state = "starting",
      source = type(cfg) == "table" and (cfg.source or "settings") or "settings",
      command = command_label(cfg),
      tool_count = 0,
      tools = as_array({}),
    }

    if type(cfg) ~= "table" then
      statuses[server_name].state = "error"
      statuses[server_name].error = "invalid MCP server config"
    elseif cfg.enabled == false or cfg.disabled == true then
      statuses[server_name].state = "disabled"
    else
      local client = Client.new(server_name, cfg, global_timeout_ms)
      local ok, err = client:start()
      if not ok then
        statuses[server_name].state = "error"
        statuses[server_name].error = tostring(err)
        io.stderr:write("psi: MCP server " .. server_name .. " disabled: " .. tostring(err) .. "\n")
      else
        local tool_list, list_err = client:list_tools()
        if not tool_list then
          client:shutdown()
          statuses[server_name].state = "error"
          statuses[server_name].error = "tools/list failed: " .. tostring(list_err)
          io.stderr:write(
            "psi: MCP server "
              .. server_name
              .. " tools/list failed: "
              .. tostring(list_err)
              .. "\n"
          )
        else
          clients[server_name] = client
          statuses[server_name].state = "ok"
          for _, remote in ipairs(tool_list) do
            local remote_name = remote.name
            local local_name = unique_tool_name(registry, used, server_name, remote_name)
            local description = remote.description or remote.title or ("MCP tool " .. remote_name)
            registered[local_name] = { server = server_name, remote = remote_name }
            statuses[server_name].tools[#statuses[server_name].tools + 1] = local_name
              .. " -> "
              .. remote_name

            registry.register(
              records.new_tool(
                local_name,
                description,
                "Call MCP tool " .. server_name .. "/" .. remote_name,
                { "Use " .. local_name .. " when the user asks for " .. description },
                remote.inputSchema or { type = "object", properties = {}, required = as_array({}) },
                function(input)
                  local result = client:call_tool(local_name, remote_name, input)
                  return records.new_tool_result(
                    result.ok,
                    local_name,
                    result.error,
                    result.extras or {}
                  )
                end,
                { execution_mode = "sequential" }
              )
            )
          end
          statuses[server_name].tool_count = #statuses[server_name].tools
        end
      end
    end
  end
end

function M.clients()
  return clients
end

function M.registered_tools()
  return registered
end

local function copy_status(status)
  local out = {}
  for k, v in pairs(status) do
    if k == "tools" and type(v) == "table" then
      local tools = {}
      for i, tool in ipairs(v) do
        tools[i] = tool
      end
      out.tools = tools
    else
      out[k] = v
    end
  end
  return out
end

function M.statuses()
  local out = {}
  for _, status in pairs(statuses) do
    out[#out + 1] = copy_status(status)
  end
  table.sort(out, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

function M.status_text(opts)
  opts = opts or {}
  local list = M.statuses()
  if #list == 0 then
    return table.concat({
      "MCP servers: none",
      "Set FORGEJO_URL and FORGEJO_ACCESS_TOKEN, LINEAR_API_KEY, LINEAR_MCP_AUTO,",
      "or mcp.servers in psi settings.",
    }, "\n")
  end

  local lines = { "MCP servers:" }
  local tool_limit = opts.tool_limit or 30
  for _, status in ipairs(list) do
    local line = string.format(
      "- %s [%s] tools=%d",
      tostring(status.name),
      tostring(status.state or "unknown"),
      tonumber(status.tool_count) or 0
    )
    if status.source then
      line = line .. " source=" .. tostring(status.source)
    end
    if status.command then
      line = line .. " command=" .. tostring(status.command)
    end
    lines[#lines + 1] = line
    if status.error then
      lines[#lines + 1] = "  error: " .. tostring(status.error)
    end
    if opts.tools and type(status.tools) == "table" then
      for i, tool in ipairs(status.tools) do
        if i > tool_limit then
          lines[#lines + 1] = "  ... +" .. tostring(#status.tools - tool_limit) .. " more"
          break
        end
        lines[#lines + 1] = "  " .. tostring(tool)
      end
    end
  end
  return table.concat(lines, "\n")
end

function M.shutdown_all()
  for _, client in pairs(clients) do
    client:shutdown()
  end
end

return M
