-- Bundled pull-request status provider.
--
-- GitHub and Forgejo policy stays in Lua. Network work runs through the
-- existing pollable process boundary and is cached for the lifetime of the
-- provider; the TUI thread only performs zero-timeout polls.

local metadata = require("psi.project_metadata")
local prelude = require("psi.prelude")

local M = {}

local STARTUP_HOOK_NAME = "pull-request-status"
local status_hook_id = nil
local status_poller_id = nil
local active_provider = nil

local function enabled()
  local value = os.getenv("PSI_PR_STATUS")
  return value ~= "0" and value ~= "false" and value ~= "off"
end

local function url_encode(text)
  return (
    tostring(text or ""):gsub("([^%w%-._~])", function(ch)
      return string.format("%%%02X", ch:byte())
    end)
  )
end

local function strip_repo_suffix(path)
  path = tostring(path or ""):gsub("^/+", ""):gsub("/+$", "")
  return path:gsub("%.git$", "")
end

local function parse_remote(url)
  local scheme, authority, path = tostring(url or ""):match("^(https?)://([^/]+)/(.+)$")
  if not scheme then
    authority, path = tostring(url or ""):match("^ssh://([^/]+)/(.+)$")
    scheme = authority and "https" or nil
  end
  if not authority then
    authority, path = tostring(url or ""):match("^[^@]+@([^:]+):(.+)$")
    scheme = authority and "https" or nil
  end
  if not authority or not path then
    return nil
  end
  local host = authority:gsub("^.-@", "")
  path = strip_repo_suffix(path)
  local owner, repo = path:match("([^/]+)/([^/]+)$")
  if not owner or not repo then
    return nil
  end
  return {
    kind = host:lower() == "github.com" and "github" or "forgejo",
    scheme = scheme,
    host = host,
    owner = owner,
    repo = repo,
  }
end

local function query_for(remote, branch)
  local headers = { "-H", "Accept: application/json" }
  local url
  if remote.kind == "github" then
    url = "https://api.github.com/repos/"
      .. url_encode(remote.owner)
      .. "/"
      .. url_encode(remote.repo)
      .. "/pulls?state=open&head="
      .. url_encode(remote.owner .. ":" .. branch)
      .. "&per_page=1"
  else
    url = remote.scheme
      .. "://"
      .. remote.host
      .. "/api/v1/repos/"
      .. url_encode(remote.owner)
      .. "/"
      .. url_encode(remote.repo)
      .. "/pulls?state=open&limit=50&page=1"
  end
  local argv = {
    "curl",
    "-fsS",
    "--netrc-optional",
    "--connect-timeout",
    "2",
    "--max-time",
    "5",
  }
  for _, value in ipairs(headers) do
    argv[#argv + 1] = value
  end
  argv[#argv + 1] = url
  return argv
end

local function find_pr_number(payload, remote, branch, decode)
  local parsed = decode(payload)
  if type(parsed) ~= "table" then
    return nil
  end
  for _, pull in ipairs(parsed) do
    if type(pull) == "table" and tonumber(pull.number) then
      local head = type(pull.head) == "table" and pull.head or {}
      local head_repo = type(head.repo) == "table" and head.repo.full_name or nil
      local same_branch = head.ref == nil or head.ref == branch
      local same_repo = head_repo == nil
        or tostring(head_repo):lower() == (remote.owner .. "/" .. remote.repo):lower()
      if same_branch and same_repo then
        return math.floor(tonumber(pull.number))
      end
    end
  end
  return nil
end

local function default_dependencies()
  return {
    cwd = psi.cwd,
    branch = metadata.git_branch,
    remote = metadata.git_remote,
    begin = psi.process_begin_argv,
    poll = psi.process_poll,
    finish = psi.process_finish,
    terminate = psi.process_terminate,
    decode = function(text)
      return prelude.safe_json_decode(text, nil)
    end,
  }
end

function M.new_provider(deps)
  deps = deps or default_dependencies()
  local state = {
    phase = "idle",
    handle = nil,
    number = nil,
  }

  local function start()
    local cwd = deps.cwd()
    local branch = deps.branch(cwd)
    local git_remote = deps.remote(cwd)
    local remote = git_remote and parse_remote(git_remote.url)
    if not branch or branch == "detached" or not remote or type(deps.begin) ~= "function" then
      state.phase = "done"
      return false
    end
    state.branch = branch
    state.remote = remote
    local handle = deps.begin(query_for(remote, branch))
    if handle == nil then
      state.phase = "done"
      return false
    end
    state.handle = handle
    state.phase = "running"
    return true
  end

  local function poll()
    if state.phase == "idle" then
      start()
    end
    if state.phase ~= "running" then
      return false, false
    end
    local ok, _, done = pcall(deps.poll, state.handle, 0)
    if not ok then
      state.phase = "done"
      state.handle = nil
      return false, false
    end
    if not done then
      return false, true
    end
    local finish_ok, result = pcall(deps.finish, state.handle)
    state.handle = nil
    state.phase = "done"
    if finish_ok and type(result) == "table" and tonumber(result.status) == 0 then
      state.number = find_pr_number(result.output or "", state.remote, state.branch, deps.decode)
    end
    return state.number ~= nil, false
  end

  local function text()
    if state.number then
      return "pr:#" .. tostring(state.number)
    end
    return nil
  end

  local function dispose()
    if state.handle ~= nil then
      if type(deps.terminate) == "function" then
        pcall(deps.terminate, state.handle)
      end
      pcall(deps.finish, state.handle)
      state.handle = nil
    end
    state.phase = "done"
  end

  start()
  return {
    poll = poll,
    text = text,
    pending = function()
      return state.phase == "running"
    end,
    dispose = dispose,
    _state = state,
  }
end

function M.enable(psi_state)
  if status_hook_id ~= nil then
    return true
  end
  if not enabled() then
    return false
  end
  local tui = (psi_state and psi_state.tui) or require("psi.tui_status")
  active_provider = M.new_provider()
  status_hook_id = tui.register_status_hook(function()
    return active_provider and active_provider.text() or nil
  end)
  status_poller_id = tui.register_status_poller(function()
    if not active_provider then
      return false, false
    end
    return active_provider.poll()
  end, active_provider.pending())
  return true
end

function M.disable(psi_state)
  local tui = (psi_state and psi_state.tui) or require("psi.tui_status")
  if status_hook_id ~= nil and tui.unregister_status_hook then
    tui.unregister_status_hook(status_hook_id)
  end
  if status_poller_id ~= nil and tui.unregister_status_poller then
    tui.unregister_status_poller(status_poller_id)
  end
  if active_provider then
    active_provider.dispose()
  end
  status_hook_id = nil
  status_poller_id = nil
  active_provider = nil
  return true
end

function M.register(psi_state)
  local tui = (psi_state and psi_state.tui) or require("psi.tui_status")
  tui.register_startup_hook(STARTUP_HOOK_NAME, function()
    M.disable(psi_state)
    M.enable(psi_state)
  end)
  return true
end

M._parse_remote = parse_remote
M._query_for = query_for
M._find_pr_number = find_pr_number

return M
