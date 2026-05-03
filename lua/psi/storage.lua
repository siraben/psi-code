-- psi.storage: dispatcher that routes file primitives to the right
-- backend based on path prefix.
--
--   @mem/...      -> psi.ramfs (read/write)
--   @embedded/... -> psi.embedded_source / docs (read-only)
--   anything else -> raw POSIX C primitive (when filesystem capability is on)
--
-- The dispatcher overwrites psi.file_read, psi.file_write, etc. on
-- the global psi table during boot. The original C primitives are
-- preserved on psi._raw so callers that explicitly want host-FS
-- behavior can still reach them.
--
-- The C primitives are not aware of the @mem/@embedded prefixes; they
-- treat them as literal filenames and would fail. Routing in Lua
-- keeps the prefix knowledge in one place.

local ramfs = require("psi.ramfs")

local raw = {}
for _, name in ipairs({
  "file_read",
  "read_file",
  "read_file_slice",
  "file_write",
  "file_write_secure",
  "file_write_atomic",
  "file_append",
  "file_exists",
  "file_type",
  "list_dir",
  "mkdir_p",
  "mkdir_parent",
  "tempfile_path",
}) do
  raw[name] = psi[name]
end
psi._raw = raw

local M = { raw = raw }

local function strip_embedded(path)
  if type(path) ~= "string" then
    return nil
  end
  if path == "@embedded" or path == "@embedded/" then
    return ""
  end
  return path:match("^@embedded/(.*)$")
end

local function is_embedded_path(path)
  return type(path) == "string"
    and (path == "@embedded" or path:sub(1, 10) == "@embedded/")
end

local function embedded_lookup(name)
  -- @embedded resources cover both Lua sources and docs; try Lua
  -- first since the original namespace was the embedded boot tree.
  local val = psi.embedded_source and psi.embedded_source(name)
  if val ~= nil then
    return val
  end
  if psi.embedded_doc then
    return psi.embedded_doc(name)
  end
  return nil
end

local function embedded_names()
  local names = {}
  if psi.embedded_source_names then
    for _, n in ipairs(psi.embedded_source_names()) do
      names[n] = true
    end
  end
  if psi.embedded_doc_names then
    for _, n in ipairs(psi.embedded_doc_names()) do
      names[n] = true
    end
  end
  local out = {}
  for k in pairs(names) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

-- ---- read ----

local function dispatch_read_full(path)
  if ramfs.is_mem_path(path) then
    return ramfs.read(path)
  end
  if is_embedded_path(path) then
    return embedded_lookup(strip_embedded(path))
  end
  if raw.read_file == nil then
    return nil
  end
  return raw.read_file(path)
end

function psi.read_file(path)
  return dispatch_read_full(path)
end

function psi.file_read(path)
  return dispatch_read_full(path)
end

function psi.read_file_slice(path, offset, limit, max_bytes)
  if ramfs.is_mem_path(path) then
    return ramfs.read_slice(path, offset, limit, max_bytes)
  end
  if is_embedded_path(path) then
    -- Slice over an embedded resource by reading then chopping.
    local content = embedded_lookup(strip_embedded(path))
    if content == nil then
      return nil
    end
    -- Stash into ramfs slice helper by passing a synthetic mem read.
    -- Cheapest path: replicate the slice logic via ramfs by writing
    -- temporarily? We instead inline the same shape:
    offset = math.max(offset or 0, 0)
    limit = (limit and limit > 0) and limit or 2000
    max_bytes = (max_bytes and max_bytes > 0) and max_bytes or 262144
    local lines = {}
    local total = 0
    local cursor = 1
    while cursor <= #content do
      local nl = content:find("\n", cursor, true)
      local line
      if nl then
        line = content:sub(cursor, nl - 1)
        cursor = nl + 1
      else
        line = content:sub(cursor)
        cursor = #content + 1
      end
      if total >= offset and total < offset + limit then
        lines[#lines + 1] = line
      end
      total = total + 1
    end
    local text = table.concat(lines, "\n")
    local truncated_bytes = false
    if #text > max_bytes then
      text = text:sub(1, max_bytes)
      truncated_bytes = true
    end
    return {
      text = text,
      total_lines = total,
      offset = offset,
      limit = limit,
      next_offset = (offset + limit < total) and (offset + limit) or nil,
      truncated = truncated_bytes or (offset + limit < total),
      truncated_bytes = truncated_bytes,
    }
  end
  if raw.read_file_slice == nil then
    return nil
  end
  return raw.read_file_slice(path, offset, limit, max_bytes)
end

-- ---- write ----

local function dispatch_write(path, content)
  if ramfs.is_mem_path(path) then
    return ramfs.write(path, content)
  end
  if is_embedded_path(path) then
    return false
  end
  if raw.file_write == nil then
    return false
  end
  return raw.file_write(path, content)
end

function psi.file_write(path, content)
  return dispatch_write(path, content)
end

function psi.file_write_secure(path, content)
  if ramfs.is_mem_path(path) then
    -- "Secure" in RAMFS context: there's no permissions model, so
    -- the secure variant is just a plain write per plan.md.
    return ramfs.write(path, content)
  end
  if is_embedded_path(path) then
    return false
  end
  if raw.file_write_secure == nil then
    return false
  end
  return raw.file_write_secure(path, content)
end

function psi.file_write_atomic(path, content)
  if ramfs.is_mem_path(path) then
    return ramfs.write(path, content)
  end
  if is_embedded_path(path) then
    return false
  end
  if raw.file_write_atomic == nil then
    return false
  end
  return raw.file_write_atomic(path, content)
end

function psi.file_append(path, content)
  if ramfs.is_mem_path(path) then
    return ramfs.append(path, content)
  end
  if is_embedded_path(path) then
    return false
  end
  if raw.file_append == nil then
    return false
  end
  return raw.file_append(path, content)
end

-- ---- metadata / dirs ----

function psi.file_exists(path)
  if ramfs.is_mem_path(path) then
    return ramfs.exists(path)
  end
  if is_embedded_path(path) then
    local name = strip_embedded(path)
    if name == "" then
      return true
    end
    if embedded_lookup(name) ~= nil then
      return true
    end
    -- A virtual directory: any embedded name with this prefix.
    local pfx = name .. "/"
    for _, n in ipairs(embedded_names()) do
      if n:sub(1, #pfx) == pfx then
        return true
      end
    end
    return false
  end
  if raw.file_exists == nil then
    return false
  end
  return raw.file_exists(path)
end

function psi.file_type(path)
  if ramfs.is_mem_path(path) then
    return ramfs.file_type(path)
  end
  if is_embedded_path(path) then
    local name = strip_embedded(path)
    if name == "" then
      return "directory"
    end
    if embedded_lookup(name) ~= nil then
      return "file"
    end
    local pfx = name .. "/"
    for _, n in ipairs(embedded_names()) do
      if n:sub(1, #pfx) == pfx then
        return "directory"
      end
    end
    return nil
  end
  if raw.file_type == nil then
    return nil
  end
  return raw.file_type(path)
end

function psi.list_dir(path)
  if ramfs.is_mem_path(path) then
    return ramfs.list_dir(path)
  end
  if is_embedded_path(path) then
    local name = strip_embedded(path)
    local prefix = (name == "") and "" or (name .. "/")
    local seen = {}
    local out = {}
    for _, n in ipairs(embedded_names()) do
      if n:sub(1, #prefix) == prefix then
        local rest = n:sub(#prefix + 1)
        local first = rest:match("^([^/]+)")
        if first and not seen[first] then
          seen[first] = true
          out[#out + 1] = first
        end
      end
    end
    table.sort(out)
    return out
  end
  if raw.list_dir == nil then
    return nil
  end
  return raw.list_dir(path)
end

function psi.mkdir_p(path)
  if ramfs.is_mem_path(path) then
    return ramfs.mkdir_p(path)
  end
  if is_embedded_path(path) then
    -- Embedded namespace is read-only; treat existing dirs as success.
    return psi.file_type(path) == "directory"
  end
  if raw.mkdir_p == nil then
    return false
  end
  return raw.mkdir_p(path)
end

-- ---- tempfile ----
-- The C primitive points at the host tmpdir. When filesystem
-- capability is off but ramfs is on, generate a memory-backed temp
-- path instead so spillover (e.g. tool_shell large output) keeps
-- working. Desktop builds keep host /tmp.
function psi.tempfile_path(prefix)
  local caps = (psi.runtime_info().capabilities) or {}
  if not caps.filesystem and caps.ramfs then
    return ramfs.tempfile_path(prefix)
  end
  if raw.tempfile_path == nil then
    if caps.ramfs then
      return ramfs.tempfile_path(prefix)
    end
    return nil
  end
  return raw.tempfile_path(prefix)
end

function psi.mkdir_parent(path)
  if ramfs.is_mem_path(path) then
    -- Strip the leaf and mkdir_p the parent.
    local stripped = ramfs.strip_prefix(path)
    if stripped == nil or stripped == "/" then
      return true
    end
    local parent = stripped:match("^(.+)/[^/]+$") or "/"
    return ramfs.mkdir_p("@mem" .. parent)
  end
  if is_embedded_path(path) then
    return false
  end
  if raw.mkdir_parent == nil then
    return false
  end
  return raw.mkdir_parent(path)
end

-- ---- stdlib shims ----
-- Lua's built-in io.open / dofile / loadfile / os.remove / os.rename
-- / os.tmpname / io.lines go straight through libc and bypass our
-- dispatcher. We replace each with a transparent prefix-aware shim:
--
--   * @mem/  and @embedded/ paths route through ramfs / embedded.
--   * Anything else falls through to the original libc path when
--     PSI_CAP_FILESYSTEM=1, or fails with a clear message when off.
--
-- This is transparent to user code: agents and extensions can keep
-- using io.open and dofile without knowing about the namespaces, and
-- a constrained build still rejects host paths everywhere.
local function install_stdlib_shims()
  local caps = (psi.runtime_info().capabilities) or {}
  local fs_enabled = caps.filesystem == true

  local function is_namespaced(p)
    return ramfs.is_mem_path(p) or is_embedded_path(p)
  end

  local function read_namespaced(p)
    if ramfs.is_mem_path(p) then
      return ramfs.read(p)
    end
    if is_embedded_path(p) then
      return embedded_lookup(strip_embedded(p))
    end
    return nil
  end

  local function host_fs_error(op)
    return nil, "filesystem disabled: " .. op .. " requires PSI_CAP_FILESYSTEM"
  end

  -- io.open returns a file-handle table with read/write/close/lines.
  -- We only implement what the agent and helpers actually use; calling
  -- an unsupported method raises rather than silently misbehaving.
  local function mem_read_handle(path, content)
    local pos = 1
    local h = { _path = path, _closed = false }
    function h:read(fmt)
      if self._closed then
        return nil, "closed"
      end
      fmt = fmt or "l"
      if type(fmt) == "number" then
        if pos > #content then
          return nil
        end
        local chunk = content:sub(pos, pos + fmt - 1)
        pos = pos + #chunk
        return chunk
      end
      local key = type(fmt) == "string" and fmt:gsub("^%*", "") or fmt
      if key == "a" then
        local rest = content:sub(pos)
        pos = #content + 1
        return rest
      end
      if key == "l" or key == "L" then
        if pos > #content then
          return nil
        end
        local nl = content:find("\n", pos, true)
        local line
        if nl then
          line = content:sub(pos, key == "L" and nl or nl - 1)
          pos = nl + 1
        else
          line = content:sub(pos)
          pos = #content + 1
        end
        return line
      end
      if key == "n" then
        return nil, "io.read('n') not supported on @mem/ handles"
      end
      return nil, "unknown read format"
    end
    function h:lines(...)
      local fmts = { ... }
      if #fmts == 0 then
        fmts = { "l" }
      end
      return function()
        return self:read(table.unpack(fmts))
      end
    end
    function h:seek(whence, offset)
      whence = whence or "cur"
      offset = offset or 0
      if whence == "set" then
        pos = offset + 1
      elseif whence == "cur" then
        pos = pos + offset
      elseif whence == "end" then
        pos = #content + 1 + offset
      end
      return pos - 1
    end
    function h:close()
      self._closed = true
      return true
    end
    return h
  end

  local function mem_write_handle(path, append)
    local buf = append and (ramfs.read(path) or "") or ""
    local h = { _path = path, _closed = false }
    function h:write(...)
      if self._closed then
        return nil, "closed"
      end
      local parts = { ... }
      for i = 1, #parts do
        buf = buf .. tostring(parts[i])
      end
      return self
    end
    function h:close()
      if self._closed then
        return true
      end
      self._closed = true
      return ramfs.write(path, buf) and true or nil, "ramfs write failed"
    end
    function h:flush()
      ramfs.write(path, buf)
      return self
    end
    return h
  end

  local original_io_open = io.open
  M.host_io_open = original_io_open
  function io.open(path, mode)
    mode = mode or "r"
    if is_embedded_path(path) then
      if mode ~= "r" and mode ~= "rb" then
        return nil, "@embedded/ is read-only"
      end
      local content = read_namespaced(path)
      if content == nil then
        return nil, "no such embedded resource: " .. tostring(path)
      end
      return mem_read_handle(path, content)
    end
    if ramfs.is_mem_path(path) then
      if mode == "r" or mode == "rb" then
        local content = ramfs.read(path)
        if content == nil then
          return nil, "no such file: " .. tostring(path)
        end
        return mem_read_handle(path, content)
      end
      if mode == "w" or mode == "wb" then
        ramfs.write(path, "")
        return mem_write_handle(path, false)
      end
      if mode == "a" or mode == "ab" then
        return mem_write_handle(path, true)
      end
      return nil, "unsupported mode for @mem/: " .. tostring(mode)
    end
    if fs_enabled then
      return original_io_open(path, mode)
    end
    return host_fs_error("io.open")
  end

  local original_loadfile = loadfile
  M.host_loadfile = original_loadfile
  function loadfile(path, chunk_mode, env)
    -- Default the chunk env to the caller's globals so loaded code
    -- runs with the usual access to print, require, psi, etc.
    -- Without this, load(...) with nil env produces a chunk whose
    -- _ENV upvalue is nil and bombs on the first global lookup.
    if env == nil then
      env = _G
    end
    if is_namespaced(path) then
      local content = read_namespaced(path)
      if content == nil then
        return nil, "no such file: " .. tostring(path)
      end
      return load(content, "@" .. path, chunk_mode, env)
    end
    if fs_enabled then
      return original_loadfile(path, chunk_mode, env)
    end
    return host_fs_error("loadfile")
  end

  local original_dofile = dofile
  M.host_dofile = original_dofile
  function dofile(path)
    if path == nil then
      if fs_enabled then
        return original_dofile()
      end
      error("filesystem disabled: dofile() without path is unavailable", 2)
    end
    local chunk, err = loadfile(path)
    if not chunk then
      error(err, 2)
    end
    return chunk()
  end

  local original_io_lines = io.lines
  function io.lines(path, ...)
    if path == nil then
      return original_io_lines(...)
    end
    if is_namespaced(path) then
      local h, err = io.open(path, "r")
      if not h then
        error(err, 2)
      end
      return h:lines(...)
    end
    if fs_enabled then
      return original_io_lines(path, ...)
    end
    error("filesystem disabled: io.lines requires PSI_CAP_FILESYSTEM", 2)
  end

  local original_os_remove = os.remove
  os.remove = function(path)
    if ramfs.is_mem_path(path) then
      if ramfs.unlink(path) then
        return true
      end
      return nil, "no such file"
    end
    if is_embedded_path(path) then
      return nil, "@embedded/ is read-only"
    end
    if fs_enabled then
      return original_os_remove(path)
    end
    return host_fs_error("os.remove")
  end

  local original_os_rename = os.rename
  os.rename = function(old, new)
    local both_mem = ramfs.is_mem_path(old) and ramfs.is_mem_path(new)
    if both_mem then
      local data = ramfs.read(old)
      if data == nil then
        return nil, "no such file: " .. tostring(old)
      end
      if not ramfs.write(new, data) then
        return nil, "rename failed"
      end
      ramfs.unlink(old)
      return true
    end
    if ramfs.is_mem_path(old) or ramfs.is_mem_path(new) then
      return nil, "cannot rename across @mem/ boundary"
    end
    if is_embedded_path(old) or is_embedded_path(new) then
      return nil, "@embedded/ is read-only"
    end
    if fs_enabled then
      return original_os_rename(old, new)
    end
    return host_fs_error("os.rename")
  end

  local original_os_tmpname = os.tmpname
  os.tmpname = function()
    if not fs_enabled then
      return ramfs.tempfile_path("psi-")
    end
    return original_os_tmpname()
  end

  -- When filesystem is off, also lock down dynamic-library loading
  -- and on-disk module search since those go through libc directly
  -- and the dispatcher cannot intercept them. With FS on, leave them
  -- alone — desktop builds rely on package.path for require().
  if not fs_enabled then
    if package and package.loadlib then
      package.loadlib = function()
        return nil, "filesystem disabled: package.loadlib unavailable"
      end
    end
    if package and package.searchers then
      package.searchers = {
        package.searchers[1], -- preload
        function(name)
          local content = psi.embedded_source and psi.embedded_source(name)
          if content == nil then
            return "\n\tno embedded module '" .. tostring(name) .. "'"
          end
          local chunk, err = load(content, "=" .. name, "t", _G)
          if not chunk then
            return err
          end
          return chunk
        end,
      }
    end
  end
end

install_stdlib_shims()
M.install_stdlib_shims = install_stdlib_shims

return M
