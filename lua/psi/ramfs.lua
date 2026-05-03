-- psi.ramfs: volatile in-memory filesystem.
--
-- Flat map of normalized paths ("/foo/bar.txt") to immutable Lua
-- strings. Directories are virtual: a path is a directory iff some
-- stored file's path begins with "<path>/". Atomic replace is a
-- single table-store, since strings are immutable.
--
-- Quotas: total stored bytes capped at M.bytes_cap; entry count at
-- M.max_files. Both are advisory and easily raised.

local M = {}

M.bytes_cap = 1024 * 1024
M.max_files = 256

local files = {} -- normalized_path -> string
local used_bytes = 0
local file_count = 0

-- Normalize a stripped path (caller has already removed the "@mem/"
-- prefix). Returns "/foo/bar" with no trailing slash, "/" for root,
-- or nil if the path tries to escape (..).
local function normalize(path)
  if type(path) ~= "string" then
    return nil
  end
  -- Strip leading slashes; collapse runs of slashes; track segments.
  local segments = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      return nil
    elseif seg ~= "." and seg ~= "" then
      segments[#segments + 1] = seg
    end
  end
  if #segments == 0 then
    return "/"
  end
  return "/" .. table.concat(segments, "/")
end

-- Strip "@mem/" or "@mem" prefix. Returns nil if not a memory path.
function M.strip_prefix(path)
  if type(path) ~= "string" then
    return nil
  end
  if path == "@mem" or path == "@mem/" then
    return "/"
  end
  local rest = path:match("^@mem/(.*)$")
  if rest == nil then
    return nil
  end
  return normalize(rest)
end

function M.is_mem_path(path)
  return type(path) == "string" and (path == "@mem" or path:sub(1, 5) == "@mem/")
end

local function to_mem_path(norm)
  if norm == "/" then
    return "@mem/"
  end
  return "@mem" .. norm
end

local function is_dir(norm)
  if norm == "/" then
    return true
  end
  local prefix = norm .. "/"
  for k in pairs(files) do
    if k:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function path_collides_with_dir(norm)
  -- Cannot create file at "/foo" if "/foo/bar" exists.
  return is_dir(norm) and norm ~= "/"
end

local function parent_collides_with_file(norm)
  -- Cannot create "/foo/bar" if "/foo" exists as a file.
  local segs = {}
  for seg in norm:gmatch("[^/]+") do
    segs[#segs + 1] = seg
  end
  for i = 1, #segs - 1 do
    local prefix = "/" .. table.concat(segs, "/", 1, i)
    if files[prefix] ~= nil then
      return true
    end
  end
  return false
end

function M.exists(path)
  local norm = M.strip_prefix(path)
  if norm == nil then
    return false
  end
  if norm == "/" then
    return true
  end
  if files[norm] ~= nil then
    return true
  end
  return is_dir(norm)
end

function M.file_type(path)
  local norm = M.strip_prefix(path)
  if norm == nil then
    return nil
  end
  if norm == "/" then
    return "directory"
  end
  if files[norm] ~= nil then
    return "file"
  end
  if is_dir(norm) then
    return "directory"
  end
  return nil
end

function M.read(path)
  local norm = M.strip_prefix(path)
  if norm == nil then
    return nil
  end
  return files[norm]
end

local function set_file(norm, content)
  local old = files[norm]
  local old_len = old and #old or 0
  local new_len = #content
  local new_count = file_count + (old == nil and 1 or 0)
  local new_bytes = used_bytes - old_len + new_len
  if new_count > M.max_files then
    return false, "ramfs: file count limit reached"
  end
  if new_bytes > M.bytes_cap then
    return false, "ramfs: byte quota exceeded"
  end
  files[norm] = content
  used_bytes = new_bytes
  file_count = new_count
  return true
end

function M.write(path, content)
  local norm = M.strip_prefix(path)
  if norm == nil or norm == "/" then
    return false
  end
  if type(content) ~= "string" then
    content = tostring(content or "")
  end
  if path_collides_with_dir(norm) then
    return false
  end
  if parent_collides_with_file(norm) then
    return false
  end
  local ok = set_file(norm, content)
  return ok and true or false
end

function M.append(path, content)
  local norm = M.strip_prefix(path)
  if norm == nil or norm == "/" then
    return false
  end
  if type(content) ~= "string" then
    content = tostring(content or "")
  end
  if path_collides_with_dir(norm) then
    return false
  end
  if parent_collides_with_file(norm) then
    return false
  end
  local existing = files[norm] or ""
  local ok = set_file(norm, existing .. content)
  return ok and true or false
end

function M.mkdir_p(path)
  -- Directories are implicit; this only validates that no parent is a file.
  local norm = M.strip_prefix(path)
  if norm == nil then
    return false
  end
  if norm == "/" then
    return true
  end
  if files[norm] ~= nil then
    -- existing file at the directory location
    return false
  end
  return not parent_collides_with_file(norm)
end

function M.list_dir(path)
  local norm = M.strip_prefix(path)
  if norm == nil then
    return nil
  end
  if norm ~= "/" and files[norm] ~= nil then
    return nil
  end
  local prefix = norm == "/" and "/" or (norm .. "/")
  local seen = {}
  local out = {}
  for k in pairs(files) do
    if k:sub(1, #prefix) == prefix then
      local rest = k:sub(#prefix + 1)
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

local temp_counter = 0
function M.tempfile_path(prefix)
  prefix = prefix or "psi-"
  temp_counter = temp_counter + 1
  local stamp = tostring(os.time()) .. "-" .. tostring(temp_counter)
  return "@mem/tmp/" .. prefix .. stamp
end

function M.unlink(path)
  local norm = M.strip_prefix(path)
  if norm == nil or norm == "/" then
    return false
  end
  local old = files[norm]
  if old == nil then
    return false
  end
  files[norm] = nil
  used_bytes = used_bytes - #old
  file_count = file_count - 1
  return true
end

function M.stats()
  return {
    bytes = used_bytes,
    bytes_cap = M.bytes_cap,
    files = file_count,
    max_files = M.max_files,
  }
end

function M.reset()
  files = {}
  used_bytes = 0
  file_count = 0
end

-- Read a slice of a stored file with the same shape as
-- psi.read_file_slice. offset is 0-based line index, limit is
-- max lines. text excludes the trailing "\n" of the last included
-- line, matching the C primitive.
function M.read_slice(path, offset, limit, max_bytes)
  offset = math.max(offset or 0, 0)
  limit = limit or 2000
  if limit <= 0 then
    limit = 1
  end
  max_bytes = max_bytes or 262144
  if max_bytes <= 0 then
    max_bytes = 262144
  end
  local content = M.read(path)
  if content == nil then
    return nil
  end
  local lines = {}
  local total = 0
  local start_line = offset
  local end_line = offset + limit
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
    if total >= start_line and total < end_line then
      lines[#lines + 1] = line
    end
    total = total + 1
    if not nl and line == "" and cursor > #content then
      total = total - 1
      break
    end
  end
  local text = table.concat(lines, "\n")
  if #text > max_bytes then
    text = text:sub(1, max_bytes)
    return {
      text = text,
      total_lines = total,
      offset = offset,
      limit = limit,
      next_offset = (offset + limit < total) and (offset + limit) or nil,
      truncated = true,
      truncated_bytes = true,
    }
  end
  return {
    text = text,
    total_lines = total,
    offset = offset,
    limit = limit,
    next_offset = (offset + limit < total) and (offset + limit) or nil,
    truncated = (offset + limit < total),
    truncated_bytes = false,
  }
end

M.to_mem_path = to_mem_path

return M
