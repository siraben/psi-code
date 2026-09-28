--[==[psi-test
expect = "true"
cwd = "classic-theme"
files = [
  { path = "{TMP}/classic-theme/.psi/settings.json", json = { theme = "dark" } },
]
]==]
-- Colors observed in the Pi 0.84.4 tmux pane and its bundled theme JSON.
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local markdown = require("psi.markdown")
local startup = require("psi.tui_startup")
ansi.enabled = true
ansi.color_enabled = true
assert(theme.current_name() == "dark")
assert(ansi.resolve("36") == "38;2;138;190;183")
assert(ansi.resolve("32") == "38;2;181;189;104")
assert(ansi.resolve("48;5;238") == "48;2;52;53;65")
assert(startup.render():find("\27[1;38;2;138;190;183mpsi", 1, true))
assert(startup.render():find("\27[38;2;102;102;102mEsc", 1, true))
assert(markdown.render("# Heading"):find("38;2;240;198;116", 1, true))
assert(markdown.render_inline("[link](url)"):find("38;2;102;102;102", 1, true))
local levels = { "off", "minimal", "low", "medium", "high", "xhigh", "max" }
for _, spec in ipairs({
  { "dark", { "80;80;80", "110;110;110", "95;135;175", "129;162;190", "178;148;187", "209;131;232", "255;95;255" } },
  { "light", { "176;176;176", "118;118;118", "84;125;167", "90;128;128", "135;95;135", "139;0;139", "175;0;95" } },
}) do
  assert(theme.use(spec[1]))
  for i, level in ipairs(levels) do
    assert(ansi.resolve("thinking-" .. level) == "38;2;" .. spec[2][i])
  end
end
return true
