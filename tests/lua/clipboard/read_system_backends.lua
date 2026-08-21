--[==[psi-test
expect = "wayland|wl-paste|wl-paste|true|wl-paste|x11|xsel|wl-paste,xclip,xsel|mac|pbpaste|win|powershell|true"
]==]
local clipboard = require("psi.clipboard")

local function run(env, is_windows, results)
  local calls = {}
  local text, backend, err = clipboard.read_system({
    env = env,
    is_windows = is_windows,
    run_argv = function(argv)
      local name = argv[1]
      calls[#calls + 1] = name
      return results[name] or { status = 1, output = "" }
    end,
  })
  return text, backend, err, table.concat(calls, ",")
end

local way_text, way_backend, _, way_calls = run(
  { WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" },
  false,
  { ["wl-paste"] = { status = 0, output = "wayland" } }
)

-- An empty but successful Wayland read must not fall back to stale X11 text.
local empty_text, empty_backend, _, empty_calls = run(
  { WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" },
  false,
  {
    ["wl-paste"] = { status = 0, output = "" },
    xclip = { status = 0, output = "stale" },
  }
)

local x_text, x_backend, _, x_calls = run(
  { WAYLAND_DISPLAY = "wayland-0", DISPLAY = ":0" },
  false,
  {
    ["wl-paste"] = { status = 1, output = "" },
    xclip = { status = 1, output = "" },
    xsel = { status = 0, output = "x11" },
  }
)

local mac_text, mac_backend = run({}, false, { pbpaste = { status = 0, output = "mac" } })
local win_text, win_backend = run({}, true, { ["powershell.exe"] = { status = 0, output = "win" } })

local large_text, _, large_err = run(
  { DISPLAY = ":0" },
  false,
  { xclip = { status = 0, output = "partial", truncated = true } }
)

return table.concat({
  way_text,
  way_backend,
  way_calls,
  tostring(empty_text == nil and empty_calls == "wl-paste"),
  empty_backend,
  x_text,
  x_backend,
  x_calls,
  mac_text,
  mac_backend,
  win_text,
  win_backend,
  tostring(large_text == nil and large_err == "clipboard text too large"),
}, "|")
