-- psi.clipboard_image: bounded platform clipboard-image readers.
--
-- Binary process output cannot safely pass through psi's text-oriented
-- process-result API, so backends write into a host-created 0600 temp file.
-- The file is bounded where practical, read with the host's hard size cap,
-- magic-sniffed, and renamed to the matching extension before it is exposed.

local clipboard = require("psi.clipboard")
local mime = require("psi.mime")
local platform = require("psi.platform")

local M = {}

local DEFAULT_TIMEOUT_MS = 5000
local MAX_IMAGE_BYTES = 16 * 1024 * 1024
local MAX_CAPTURE_BYTES = MAX_IMAGE_BYTES + 1

local SUPPORTED_MIMES = {
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
}

local EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/webp"] = "webp",
  ["image/gif"] = "gif",
}

local MACOS_SCRIPT = [[
on run argv
  set outputPath to item 1 of argv
  try
    set imageData to the clipboard as «class PNGf»
    if (length of imageData) > 16777216 then return "too-large"
    set fileRef to open for access POSIX file outputPath with write permission
    try
      set eof fileRef to 0
      write imageData to fileRef
      close access fileRef
      return "ok"
    on error
      try
        close access fileRef
      end try
      return "error"
    end try
  on error
    return "empty"
  end try
end run
]]

local WINDOWS_SCRIPT = table.concat({
  "Add-Type -AssemblyName System.Windows.Forms",
  "Add-Type -AssemblyName System.Drawing",
  "$img = [System.Windows.Forms.Clipboard]::GetImage()",
  "if ($null -eq $img) { exit 3 }",
  "if (([int64]$img.Width * [int64]$img.Height) -gt 4000000) { exit 4 }",
  "$stream = New-Object System.IO.MemoryStream",
  "try {",
  "$img.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)",
  "if ($stream.Length -gt 16777216) { exit 4 }",
  "[System.IO.File]::WriteAllBytes($path, $stream.ToArray())",
  "} finally { $stream.Dispose(); $img.Dispose() }",
}, "; ")

local function context_env(context, name)
  if type(context.env) == "table" then
    return context.env[name]
  end
  return os.getenv(name)
end

local function env_nonempty(context, name)
  local value = context_env(context, name)
  return value ~= nil and value ~= ""
end

local function base_mime(value)
  local base = tostring(value or ""):match("^%s*([^;]+)")
  return base and base:lower():gsub("%s+$", "") or ""
end

local function supported_mime(value)
  local normalized = base_mime(value)
  return EXTENSIONS[normalized] and normalized or nil
end

local function listed_mimes(output)
  local found = {}
  for value in tostring(output or ""):gmatch("[^\r\n]+") do
    local raw = value:match("^%s*(.-)%s*$")
    local normalized = supported_mime(value)
    if normalized ~= nil and found[normalized] == nil then
      found[normalized] = raw
    end
  end
  local ordered = {}
  for _, value in ipairs(SUPPORTED_MIMES) do
    if found[value] then
      ordered[#ordered + 1] = { base = value, raw = found[value] }
    end
  end
  return ordered
end

local function append_unique_mime(values, raw)
  local base = supported_mime(raw)
  if base == nil then
    return
  end
  for _, existing in ipairs(values) do
    if existing.base == base then
      return
    end
  end
  values[#values + 1] = { base = base, raw = raw }
end

local function command_ok(result)
  return type(result) == "table" and tonumber(result.status) == 0 and result.truncated ~= true
end

local function run_command(argv, context)
  return clipboard._run_read_command(argv, context)
end

local function powershell_literal(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function default_image_runner(backend, path, context)
  if backend.kind == "wayland" then
    return run_command({
      "sh",
      "-c",
      '"$1" --type "$2" --no-newline | head -c "$3" > "$4"',
      "psi-clipboard",
      "wl-paste",
      backend.mime,
      tostring(MAX_CAPTURE_BYTES),
      path,
    }, context)
  end
  if backend.kind == "xclip" then
    return run_command({
      "sh",
      "-c",
      '"$1" -selection clipboard -t "$2" -o | head -c "$3" > "$4"',
      "psi-clipboard",
      "xclip",
      backend.mime,
      tostring(MAX_CAPTURE_BYTES),
      path,
    }, context)
  end
  if backend.kind == "macos" then
    return run_command({ "osascript", "-e", MACOS_SCRIPT, path }, context)
  end
  if backend.kind == "windows" then
    local script = "$path = " .. powershell_literal(path) .. "; " .. WINDOWS_SCRIPT
    return run_command({
      "powershell.exe",
      "-NoProfile",
      "-NonInteractive",
      "-STA",
      "-Command",
      script,
    }, context)
  end
  return { status = -1, output = "", truncated = false }
end

local function run_image_backend(backend, path, context)
  local runner = context.run_image_backend or default_image_runner
  local ok, result = pcall(runner, backend, path, context)
  if not ok then
    return false
  end
  return command_ok(result)
end

local function new_staging_path()
  if type(psi.tempfile_path) ~= "function" then
    return nil
  end
  local ok, path = pcall(psi.tempfile_path, "psi-clipboard-")
  if not ok or type(path) ~= "string" or path == "" then
    return nil
  end
  return path
end

local function validate_and_publish(staging)
  if type(psi.read_file_limited) ~= "function" then
    return nil, "bounded file reads unavailable"
  end
  local bytes = psi.read_file_limited(staging, MAX_IMAGE_BYTES)
  if type(bytes) ~= "string" or bytes == "" then
    return nil, "clipboard image empty, unreadable, or too large"
  end
  local detected = mime.detect_supported_image_mime_from_bytes(bytes)
  local extension = EXTENSIONS[detected]
  if extension == nil then
    return nil, "unsupported clipboard image type"
  end
  local final_path = staging .. "." .. extension
  local renamed = os.rename(staging, final_path)
  if not renamed then
    return nil, "failed to finalize clipboard image"
  end
  return final_path, detected
end

local function try_backend(backend, context)
  local staging = new_staging_path()
  if staging == nil then
    return nil, "secure temp files unavailable"
  end
  if not run_image_backend(backend, staging, context) then
    os.remove(staging)
    return nil
  end
  local path, detected_or_error = validate_and_publish(staging)
  if path == nil then
    os.remove(staging)
    return nil, detected_or_error
  end
  return path, backend.name, detected_or_error
end

local function wayland_backends(context)
  local result = run_command({ "wl-paste", "--list-types" }, context)
  if not command_ok(result) then
    return {}
  end
  local out = {}
  for _, target in ipairs(listed_mimes(result.output)) do
    out[#out + 1] = {
      name = "wl-paste",
      kind = "wayland",
      mime = target.raw,
      mime_base = target.base,
    }
  end
  return out
end

local function xclip_backends(context)
  local types = {}
  local result = run_command({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, context)
  if command_ok(result) then
    for _, target in ipairs(listed_mimes(result.output)) do
      append_unique_mime(types, target.raw)
    end
  end
  for _, mime_type in ipairs(SUPPORTED_MIMES) do
    append_unique_mime(types, mime_type)
  end
  local out = {}
  for _, target in ipairs(types) do
    out[#out + 1] = {
      name = "xclip",
      kind = "xclip",
      mime = target.raw,
      mime_base = target.base,
    }
  end
  return out
end

local function image_backends(context)
  local windows = context.is_windows
  if windows == nil then
    windows = platform.is_windows()
  end
  if windows then
    return { { name = "powershell", kind = "windows", mime = "image/png" } }
  end
  if env_nonempty(context, "TERMUX_VERSION") then
    return {}
  end

  local out = {}
  local wayland = env_nonempty(context, "WAYLAND_DISPLAY")
    or context_env(context, "XDG_SESSION_TYPE") == "wayland"
  if wayland then
    for _, backend in ipairs(wayland_backends(context)) do
      out[#out + 1] = backend
    end
  end
  if wayland or env_nonempty(context, "DISPLAY") then
    for _, backend in ipairs(xclip_backends(context)) do
      out[#out + 1] = backend
    end
  end
  -- Feature detection: osascript succeeds on macOS and fails elsewhere.
  out[#out + 1] = { name = "osascript", kind = "macos", mime = "image/png" }
  return out
end

function M.extension_for_mime(mime_type)
  return EXTENSIONS[supported_mime(mime_type)]
end

-- Return a secure temp image path, backend name, and detected MIME type.
-- Unsupported/empty/oversized images return nil so callers can fall back to
-- the plain-text clipboard without changing editor state.
function M.read_system(context)
  context = type(context) == "table" and context or {}
  if type(psi.time_ms) == "function" and context.deadline_ms == nil then
    local timeout_ms = tonumber(context.timeout_ms) or DEFAULT_TIMEOUT_MS
    context.deadline_ms = psi.time_ms() + math.max(1, timeout_ms)
  end
  local last_error
  for _, backend in ipairs(image_backends(context)) do
    local path, name, mime_or_error = try_backend(backend, context)
    if path ~= nil then
      return path, name, mime_or_error
    end
    if mime_or_error ~= nil then
      last_error = mime_or_error
    end
  end
  return nil, last_error or "clipboard image unavailable"
end

M.MAX_IMAGE_BYTES = MAX_IMAGE_BYTES

return M
