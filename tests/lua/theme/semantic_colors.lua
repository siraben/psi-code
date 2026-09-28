--[==[psi-test
expect = "true|true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local theme = require("psi.theme")
local md = require("psi.markdown")
ansi.enabled = true
ansi.color_enabled = true
local out = {}
for _, spec in ipairs({
  { "pi-dark", "105;173;208", "104;183;141", "94;178;134" },
  { "pi-light", "47;120;153", "51;126;88", "64;151;108" },
}) do
  theme.use(spec[1])
  out[#out + 1] = tostring(md.render_inline("[link](url)"):find("38;2;" .. spec[2], 1, true) ~= nil)
  out[#out + 1] = tostring(md.render("```\ncode\n```"):find("38;2;" .. spec[3], 1, true) ~= nil)
  out[#out + 1] = tostring(ansi.resolve("bash-mode") == "38;2;" .. spec[4])
end
return table.concat(out, "|")
