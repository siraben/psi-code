local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path")
local mutation_queue = require("psi.tool_mutation_queue")
local helpers = require("psi.tool_helpers")
local shell = require("psi.tool_shell")

local function split_lines(text)
  local out = {}
  text = tostring(text or "")
  if text == "" then
    return out
  end
  local start = 1
  while true do
    local i = text:find("\n", start, true)
    if not i then
      out[#out + 1] = text:sub(start)
      break
    end
    out[#out + 1] = text:sub(start, i - 1)
    start = i + 1
  end
  return out
end

local function join_lines(lines)
  return table.concat(lines, "\n")
end

local function starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

local function command_ok(command)
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function rm_rf(path)
  return command_ok("rm -rf -- " .. shell.quote(path))
end

local function cp_a(src, dst)
  return command_ok("cp -a -- " .. shell.quote(src) .. " " .. shell.quote(dst))
end

local function is_symlink(path)
  return command_ok("test -L " .. shell.quote(path))
end

local function op_path(line, prefix)
  return line:sub(#prefix + 1):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
end

local function parse_patch(patch)
  local lines = split_lines(patch)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  if lines[1] ~= "*** Begin Patch" then
    return nil, "patch must start with *** Begin Patch"
  end
  if lines[#lines] ~= "*** End Patch" then
    return nil, "patch must end with *** End Patch"
  end

  local ops = {}
  local i = 2
  while i < #lines do
    local line = lines[i]
    if starts_with(line, "*** Add File: ") then
      local path = op_path(line, "*** Add File: ")
      local content = {}
      i = i + 1
      while i < #lines and not starts_with(lines[i], "*** ") do
        local l = lines[i]
        if not starts_with(l, "+") then
          return nil, "add-file lines must start with +"
        end
        content[#content + 1] = l:sub(2)
        i = i + 1
      end
      ops[#ops + 1] = { kind = "add", path = path, content = content }
    elseif starts_with(line, "*** Delete File: ") then
      local path = op_path(line, "*** Delete File: ")
      ops[#ops + 1] = { kind = "delete", path = path }
      i = i + 1
    elseif starts_with(line, "*** Update File: ") then
      local path = op_path(line, "*** Update File: ")
      local move_to = nil
      local hunks = {}
      local current = nil
      i = i + 1
      while
        i < #lines
        and (
          not starts_with(lines[i], "*** ")
          or starts_with(lines[i], "*** Move to: ")
          or lines[i] == "*** End of File"
        )
      do
        local l = lines[i]
        if starts_with(l, "*** Move to: ") then
          move_to = op_path(l, "*** Move to: ")
        elseif starts_with(l, "@@") then
          if current then
            hunks[#hunks + 1] = current
          end
          current = { old = {}, new = {} }
        elseif l == "*** End of File" then
          -- Marker is accepted for compatibility with Codex-style patches.
        else
          if not current then
            current = { old = {}, new = {} }
          end
          local prefix = l:sub(1, 1)
          local body = l:sub(2)
          if prefix == " " then
            current.old[#current.old + 1] = body
            current.new[#current.new + 1] = body
          elseif prefix == "-" then
            current.old[#current.old + 1] = body
          elseif prefix == "+" then
            current.new[#current.new + 1] = body
          else
            return nil, "update hunk lines must start with space, -, +, or @@"
          end
        end
        i = i + 1
      end
      if current then
        hunks[#hunks + 1] = current
      end
      ops[#ops + 1] = { kind = "update", path = path, move_to = move_to, hunks = hunks }
    elseif line == "" then
      i = i + 1
    else
      return nil, "unknown patch directive: " .. tostring(line)
    end
  end
  return ops, nil
end

local function find_sequence(lines, needle, start_at)
  if #needle == 0 then
    return start_at
  end
  for i = start_at, (#lines - #needle + 1) do
    local ok = true
    for j = 1, #needle do
      if lines[i + j - 1] ~= needle[j] then
        ok = false
        break
      end
    end
    if ok then
      return i
    end
  end
  return nil
end

local function replace_sequence(lines, at, old_len, replacement)
  local out = {}
  for i = 1, at - 1 do
    out[#out + 1] = lines[i]
  end
  for _, line in ipairs(replacement) do
    out[#out + 1] = line
  end
  for i = at + old_len, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function apply_update(path, hunks)
  if not psi.file_exists(path) then
    return false, "no such file: " .. path
  end
  local text = psi.read_file(path)
  if text == nil then
    return false, "could not read full file: " .. path
  end
  local lines = split_lines(text)
  local cursor = 1
  for h, hunk in ipairs(hunks) do
    local at = find_sequence(lines, hunk.old, cursor)
    if not at then
      return false, "hunk " .. tostring(h) .. " did not match " .. path
    end
    lines = replace_sequence(lines, at, #hunk.old, hunk.new)
    cursor = at + #hunk.new
  end
  local out = join_lines(lines)
  if not psi.file_write(path, out) then
    return false, "could not write " .. path
  end
  return true, nil
end

local function snapshot(path, snapshots, backup)
  if snapshots[path] ~= nil then
    return true, nil
  end
  if psi.file_exists(path) then
    local content = psi.read_file(path)
    if content == nil then
      return false, "could not snapshot unreadable file: " .. path
    end
    backup.next = backup.next + 1
    local backup_path = backup.root .. "/" .. tostring(backup.next)
    if not cp_a(path, backup_path) then
      return false, "could not back up file metadata: " .. path
    end
    snapshots[path] = {
      exists = true,
      content = content,
      backup_path = backup_path,
      symlink = is_symlink(path),
    }
  else
    snapshots[path] = { exists = false, content = nil }
  end
  return true, nil
end

local function restore_snapshots(snapshots)
  for path, snap in pairs(snapshots) do
    if snap.exists then
      psi.mkdir_parent(path)
      if type(snap.backup_path) == "string" and snap.backup_path ~= "" then
        rm_rf(path)
        cp_a(snap.backup_path, path)
      else
        psi.file_write(path, snap.content or "")
      end
    elseif psi.file_exists(path) then
      os.remove(path)
    end
  end
  for path, snap in pairs(snapshots) do
    if snap.exists and snap.symlink then
      psi.file_write(path, snap.content or "")
    end
  end
end

local function remember_created_parent_dirs(path, created_dirs, seen_dirs)
  local dir = psi.parent_directory(path)
  while type(dir) == "string" and dir ~= "" and dir ~= path and not psi.file_exists(dir) do
    if not seen_dirs[dir] then
      seen_dirs[dir] = true
      created_dirs[#created_dirs + 1] = dir
    end
    local parent = psi.parent_directory(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
end

local function restore_created_dirs(created_dirs)
  table.sort(created_dirs, function(a, b)
    if #a == #b then
      return a > b
    end
    return #a > #b
  end)
  for _, dir in ipairs(created_dirs) do
    if psi.file_exists(dir) then
      os.remove(dir)
    end
  end
end

local function snapshot_ops(ops)
  local snapshots = {}
  local backup = { root = psi.tempfile_path("psi-apply-patch-"), next = 0 }
  local created_dirs = {}
  local seen_dirs = {}
  if not backup.root or backup.root == "" or not psi.mkdir_p(backup.root) then
    return nil, "could not create patch backup directory"
  end
  for _, op in ipairs(ops) do
    local resolved = path_util.resolve(op.path) or op.path
    local ok, err = snapshot(resolved, snapshots, backup)
    if not ok then
      rm_rf(backup.root)
      return nil, err
    end
    if op.kind == "add" then
      remember_created_parent_dirs(resolved, created_dirs, seen_dirs)
    end
    if op.kind == "update" and type(op.move_to) == "string" and op.move_to ~= "" then
      local move_target = path_util.resolve(op.move_to) or op.move_to
      ok, err = snapshot(move_target, snapshots, backup)
      if not ok then
        rm_rf(backup.root)
        return nil, err
      end
      remember_created_parent_dirs(move_target, created_dirs, seen_dirs)
    end
  end
  return snapshots, nil, created_dirs, backup.root
end

local function apply_op(op)
  local resolved = path_util.resolve(op.path) or op.path
  return mutation_queue.with_path(resolved, function()
    if op.kind == "add" then
      if psi.file_exists(resolved) then
        return false, "file already exists: " .. op.path
      end
      if not psi.mkdir_parent(resolved) then
        return false, "could not create parent directory for " .. op.path
      end
      local content = join_lines(op.content)
      if content ~= "" and content:sub(-1) ~= "\n" then
        content = content .. "\n"
      end
      if not psi.file_write(resolved, content) then
        return false, "could not write " .. op.path
      end
      return true, nil, resolved
    elseif op.kind == "delete" then
      if not psi.file_exists(resolved) then
        return false, "no such file: " .. op.path
      end
      local ok, err = os.remove(resolved)
      if not ok then
        return false, "could not delete " .. op.path .. ": " .. tostring(err)
      end
      return true, nil, resolved
    elseif op.kind == "update" then
      local ok, err = apply_update(resolved, op.hunks)
      if not ok then
        return ok, err
      end
      if type(op.move_to) == "string" and op.move_to ~= "" then
        local target = path_util.resolve(op.move_to) or op.move_to
        if psi.file_exists(target) then
          return false, "move target already exists: " .. op.move_to
        end
        if not psi.mkdir_parent(target) then
          return false, "could not create parent directory for " .. op.move_to
        end
        local moved, move_err = os.rename(resolved, target)
        if not moved then
          return false,
            "could not move " .. op.path .. " to " .. op.move_to .. ": " .. tostring(move_err)
        end
        return true, nil, target
      end
      return ok, err, resolved
    end
    return false, "unknown operation"
  end)
end

local function impl(input)
  local patch = input.patch or input.content or input.diff
  if type(patch) ~= "string" or patch == "" then
    return records.tool_failure("apply_patch", "missing string field: patch")
  end
  local ops, err = parse_patch(patch)
  if not ops then
    return records.tool_failure("apply_patch", err)
  end

  local snapshots, snapshot_err, created_dirs, backup_root = snapshot_ops(ops)
  if not snapshots then
    return records.tool_failure("apply_patch", snapshot_err)
  end
  local files = {}
  for _, op in ipairs(ops) do
    local ok, op_err, resolved = apply_op(op)
    if not ok then
      restore_snapshots(snapshots)
      restore_created_dirs(created_dirs or {})
      rm_rf(backup_root)
      return records.tool_failure("apply_patch", op_err)
    end
    files[#files + 1] = {
      path = op.path,
      move_to = op.move_to,
      resolved_path = resolved,
      operation = op.kind,
    }
  end

  local output = "applied patch to " .. tostring(#files) .. " file(s)"
  rm_rf(backup_root)
  return records.new_tool_result(true, "apply_patch", nil, {
    output = output,
    files = files,
    changes = #files,
  })
end

return function()
  helpers.register(registry, records, {
    name = "apply_patch",
    description = "Apply a unified Codex-style patch. Use this for precise multi-file edits.",
    prompt_snippet = "Apply a structured patch to files",
    guidelines = {
      "Use apply_patch for manual file edits when a small patch is clearer than full-file rewrites.",
    },
    input_schema = helpers.schema_object({
      patch = helpers.schema_type("string"),
    }, { "patch" }),
    impl = impl,
    opts = { execution_mode = "sequential" },
  })
end
