--[==[psi-test
expect = "true"
cwd = "released-theme"
files = [
  { path = "{TMP}/released-theme/.psi/settings.json", json = { theme = "dark" } },
]
]==]
-- Exact RGB mappings from released Pi 0.87.1 (also used by installed 0.84.4).
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local markdown = require("psi.markdown")
local startup = require("psi.tui_startup")
ansi.enabled = true
ansi.color_enabled = true
assert(theme.current_name() == "dark")
assert(startup.render():find("\27[1;38;2;138;190;183mpsi", 1, true))
assert(startup.render():find("\27[38;2;102;102;102mEsc", 1, true))
assert(markdown.render("# Heading"):find("38;2;240;198;116", 1, true))
assert(markdown.render_inline("[link](url)"):find("38;2;102;102;102", 1, true))

local palettes = {
  dark = {
    ["2"] = "38;2;102;102;102",
    ["31"] = "38;2;204;102;102",
    ["32"] = "38;2;181;189;104",
    ["33"] = "38;2;255;255;0",
    ["34"] = "38;2;95;135;255",
    ["36"] = "38;2;138;190;183",
    ["37"] = "38;2;212;212;212",
    ["38;5;242"] = "38;2;128;128;128",
    ["48;5;236"] = "48;2;40;40;50",
    ["48;5;22"] = "48;2;40;50;40",
    ["48;5;52"] = "48;2;60;40;40",
    ["48;5;237"] = "48;2;58;58;74",
    ["48;5;238"] = "48;2;52;53;65",
    ["md-heading"] = "38;2;240;198;116",
    ["md-link"] = "38;2;129;162;190",
    ["md-link-url"] = "38;2;102;102;102",
    ["md-bullet"] = "38;2;138;190;183",
    ["thinking-text"] = "38;2;128;128;128",
    ["bash-mode"] = "38;2;181;189;104",
    ["thinking-off"] = "38;2;80;80;80",
    ["thinking-minimal"] = "38;2;110;110;110",
    ["thinking-low"] = "38;2;95;135;175",
    ["thinking-medium"] = "38;2;129;162;190",
    ["thinking-high"] = "38;2;178;148;187",
    ["thinking-xhigh"] = "38;2;209;131;232",
    ["thinking-max"] = "38;2;255;95;255",
  },
  light = {
    ["2"] = "38;2;118;118;118",
    ["31"] = "38;2;170;85;85",
    ["32"] = "38;2;88;132;88",
    ["33"] = "38;2;154;115;38",
    ["34"] = "38;2;84;125;167",
    ["36"] = "38;2;90;128;128",
    ["37"] = "38;2;31;35;40",
    ["38;5;242"] = "38;2;108;108;108",
    ["48;5;236"] = "48;2;232;232;240",
    ["48;5;22"] = "48;2;232;240;232",
    ["48;5;52"] = "48;2;240;232;232",
    ["48;5;237"] = "48;2;208;208;224",
    ["48;5;238"] = "48;2;232;232;232",
    ["md-heading"] = "38;2;154;115;38",
    ["md-link"] = "38;2;84;125;167",
    ["md-link-url"] = "38;2;118;118;118",
    ["md-bullet"] = "38;2;88;132;88",
    ["thinking-text"] = "38;2;108;108;108",
    ["bash-mode"] = "38;2;88;132;88",
    ["thinking-off"] = "38;2;176;176;176",
    ["thinking-minimal"] = "38;2;118;118;118",
    ["thinking-low"] = "38;2;84;125;167",
    ["thinking-medium"] = "38;2;90;128;128",
    ["thinking-high"] = "38;2;135;95;135",
    ["thinking-xhigh"] = "38;2;139;0;139",
    ["thinking-max"] = "38;2;175;0;95",
  },
}
for name, expected in pairs(palettes) do
  assert(theme.use(name))
  for slot, value in pairs(expected) do
    assert(ansi.resolve(slot) == value, name .. " " .. slot .. ": " .. tostring(ansi.resolve(slot)))
  end
end
return true
