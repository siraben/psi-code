--[==[psi-test
expect = "wl-paste|image/png|true|true|xclip|image/jpeg|true|osascript|image/jpeg|true|powershell|image/gif|true|true|true|true|png|jpg|nil|true|true|true"
]==]
local image = require("psi.clipboard_image")

local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
local jpg = string.char(0xff, 0xd8, 0xff, 0xdb)
local gif = "GIF89a"

local function cleanup(path)
  if type(path) == "string" then
    os.remove(path)
  end
end

local secure_mode = false
local way_path, way_backend, way_mime = image.read_system({
  env = { WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" },
  is_windows = false,
  run_argv = function(argv)
    if argv[1] == "wl-paste" and argv[2] == "--list-types" then
      return { status = 0, output = "text/plain\nimage/jpeg\nimage/png; charset=binary\n" }
    end
    return { status = 1, output = "" }
  end,
  run_image_backend = function(backend, path)
    secure_mode = psi.file_mode(path) == 384
    if backend.kind == "wayland" and backend.mime == "image/png; charset=binary" then
      psi.file_write(path, png)
      return { status = 0, output = "" }
    end
    return { status = 1, output = "" }
  end,
})
local way_valid = way_path ~= nil
  and way_path:sub(-4) == ".png"
  and psi.read_file_limited(way_path, 100) == png
  and psi.file_mode(way_path) == 384

local x_path, x_backend, x_mime = image.read_system({
  env = { WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" },
  is_windows = false,
  run_argv = function(argv)
    if argv[1] == "wl-paste" then
      return { status = 0, output = "image/png\n" }
    end
    if argv[1] == "xclip" and argv[5] == "TARGETS" then
      return { status = 0, output = "image/jpeg\n" }
    end
    return { status = 1, output = "" }
  end,
  run_image_backend = function(backend, path)
    if backend.kind == "wayland" then
      return { status = 1, output = "" }
    end
    if backend.kind == "xclip" and backend.mime == "image/jpeg" then
      psi.file_write(path, jpg)
      return { status = 0, output = "" }
    end
    return { status = 1, output = "" }
  end,
})

-- The detected bytes, not the backend's claim, determine the final suffix.
local mac_path, mac_backend, mac_mime = image.read_system({
  env = {},
  is_windows = false,
  run_image_backend = function(backend, path)
    if backend.kind == "macos" then
      psi.file_write(path, jpg)
      return { status = 0, output = "ok" }
    end
    return { status = 1, output = "" }
  end,
})

local win_path, win_backend, win_mime = image.read_system({
  env = {},
  is_windows = true,
  run_image_backend = function(backend, path)
    if backend.kind == "windows" then
      psi.file_write(path, gif)
      return { status = 0, output = "" }
    end
    return { status = 1, output = "" }
  end,
})

local powershell_argv
image.read_system({
  env = {},
  is_windows = true,
  run_argv = function(argv)
    powershell_argv = argv
    return { status = 1, output = "" }
  end,
})
local powershell_script = powershell_argv and powershell_argv[#powershell_argv] or ""

local termux_calls = 0
local termux_path = image.read_system({
  env = { TERMUX_VERSION = "1" },
  is_windows = false,
  run_image_backend = function()
    termux_calls = termux_calls + 1
    return { status = 0, output = "" }
  end,
})

local invalid_staging
local invalid_path = image.read_system({
  env = {},
  is_windows = false,
  run_image_backend = function(_, path)
    invalid_staging = path
    psi.file_write(path, "not an image")
    return { status = 0, output = "" }
  end,
})

local oversized_staging
local oversized_path = image.read_system({
  env = {},
  is_windows = false,
  run_image_backend = function(_, path)
    oversized_staging = path
    local file = assert(io.open(path, "wb"))
    file:write(png)
    file:write(string.rep("x", image.MAX_IMAGE_BYTES + 1))
    file:close()
    return { status = 0, output = "" }
  end,
})

local result = table.concat({
  way_backend,
  way_mime,
  tostring(secure_mode),
  tostring(way_valid),
  x_backend,
  x_mime,
  tostring(x_path ~= nil and x_path:sub(-4) == ".jpg"),
  mac_backend,
  mac_mime,
  tostring(mac_path ~= nil and mac_path:sub(-4) == ".jpg"),
  win_backend,
  win_mime,
  tostring(win_path ~= nil and win_path:sub(-4) == ".gif"),
  tostring(termux_path == nil and termux_calls == 0),
  tostring(invalid_path == nil and not psi.file_exists(invalid_staging)),
  tostring(oversized_path == nil and not psi.file_exists(oversized_staging)),
  tostring(image.extension_for_mime("IMAGE/PNG; charset=binary")),
  tostring(image.extension_for_mime("image/jpeg")),
  tostring(image.extension_for_mime("image/bmp")),
  tostring(powershell_argv ~= nil and powershell_argv[#powershell_argv - 1] == "-Command"),
  tostring(powershell_script:find("$path = '", 1, true) ~= nil),
  tostring(
    powershell_script:find("MemoryStream", 1, true) ~= nil
      and powershell_script:find("$stream.Length -gt 16777216", 1, true) ~= nil
  ),
}, "|")

cleanup(way_path)
cleanup(x_path)
cleanup(mac_path)
cleanup(win_path)

return result
