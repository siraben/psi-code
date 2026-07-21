-- psi.project_metadata: cheap project facts derived from local Git files.
--
-- Rendering calls this on every redraw, so repository discovery is cached.
-- HEAD itself stays a tiny live read so branch switches are reflected without
-- spawning git or adding filesystem-watch policy to the C host.

local prelude = require("psi.prelude")

local M = {}

local paths_by_cwd = {}

local function absolute_path(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

local function resolve_from(base, path)
  if absolute_path(path) then
    return path
  end
  return prelude.path_join(base, path)
end

local function git_file_target(repo_dir, git_file)
  local text = psi.read_file(git_file)
  local target = type(text) == "string" and text:match("^%s*gitdir:%s*(.-)%s*$") or nil
  if not target or target == "" then
    return nil
  end
  return resolve_from(repo_dir, target)
end

local function common_git_dir(git_dir)
  local text = psi.read_file(prelude.path_join(git_dir, "commondir"))
  local target = type(text) == "string" and text:match("^%s*(.-)%s*$") or nil
  if not target or target == "" then
    return git_dir
  end
  return resolve_from(git_dir, target)
end

local function discover(cwd)
  local dir = psi.path_resolve(cwd or psi.cwd()) or cwd or psi.cwd()
  while type(dir) == "string" and dir ~= "" do
    local dot_git = prelude.path_join(dir, ".git")
    local kind = psi.file_type(dot_git)
    if kind == "directory" then
      return {
        repo_dir = dir,
        git_dir = dot_git,
        common_git_dir = dot_git,
      }
    elseif kind == "file" then
      local git_dir = git_file_target(dir, dot_git)
      if git_dir then
        return {
          repo_dir = dir,
          git_dir = git_dir,
          common_git_dir = common_git_dir(git_dir),
        }
      end
      return nil
    end
    local parent = psi.parent_directory(dir)
    if not parent or parent == "" or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

function M.git_paths(cwd)
  cwd = tostring(cwd or psi.cwd() or "")
  if paths_by_cwd[cwd] == nil then
    paths_by_cwd[cwd] = discover(cwd) or false
  end
  return paths_by_cwd[cwd] or nil
end

function M.git_branch(cwd)
  local paths = M.git_paths(cwd)
  if not paths then
    return nil
  end
  local head = psi.read_file(prelude.path_join(paths.git_dir, "HEAD"))
  if type(head) ~= "string" or head == "" then
    return nil
  end
  local branch = head:match("^%s*ref:%s*refs/heads/(.-)%s*$")
  if branch and branch ~= "" then
    return branch
  end
  return "detached"
end

local function config_remotes(text)
  local current = nil
  local origin = nil
  local first = nil
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local section = line:match("^%s*%[(.-)%]%s*$")
    if section then
      current = section:match('^remote%s+"([^"]+)"$')
    else
      local key, value = line:match("^%s*([%w.-]+)%s*=%s*(.-)%s*$")
      if current and key and key:lower() == "url" and value ~= "" then
        first = first or { name = current, url = value }
        if current == "origin" then
          origin = { name = current, url = value }
        end
      end
    end
  end
  return origin or first
end

function M.git_remote(cwd)
  local paths = M.git_paths(cwd)
  if not paths then
    return nil
  end
  local text = psi.read_file(prelude.path_join(paths.common_git_dir, "config"))
  local remote = config_remotes(text)
  if remote then
    remote.repo_dir = paths.repo_dir
  end
  return remote
end

function M.clear_cache()
  paths_by_cwd = {}
end

M._config_remotes = config_remotes

return M
