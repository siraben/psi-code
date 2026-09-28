--[==[psi-test
expect = "true|true|true"
env = { PSI_ANSI = "1", PSI_COLOR = "1", PSI_THEME_BACKGROUND = "dark" }
]==]
local ansi = require("psi.ansi")
local theme = require("psi.theme")
ansi.enabled = true
ansi.color_enabled = true
local levels = { "off", "minimal", "low", "medium", "high", "xhigh", "max" }
local seen = {}
local all_colored = true
for _, level in ipairs(levels) do
  local rendered = theme.thinking_border(level, "x")
  local code = rendered:match("\27%[([^m]+)m")
  all_colored = all_colored and code ~= nil
  seen[code or level] = true
end
local medium = theme.thinking_border("medium", "x")
local maximum = theme.thinking_border("max", "x")
return table.concat({
  tostring(all_colored),
  tostring((function() local n = 0 for _ in pairs(seen) do n = n + 1 end return n == #levels end)()),
  tostring(medium:find("38;2;129;162;190", 1, true) ~= nil
    and maximum:find("38;2;255;95;255", 1, true) ~= nil),
}, "|")
