--[==[psi-test
expect = "alpha|beta|gamma|alpha beta gamma|alpha|beta|gamma|3|2|safe content|true"
]==]
local rt = require("psi.tui_runtime")
local edited = rt._debug_edit_keys("", 0, {
  { key = "text", text = "alpha\r\nbeta\rgamma" },
})
local markdown = require("psi.tui_components.markdown").new({
  text = "alpha\r\nbeta\rgamma",
})
local rendered = markdown:render(80)
local tool = require("psi.tui_components.tool_execution")

local renderer_module = require("psi.tui_renderer")
local captured
local backend = {
  can_diff = function()
    return true
  end,
  reset = function() end,
  render_full = function(_, frame)
    captured = frame
  end,
}
local renderer = renderer_module.new({ backend = backend })
renderer:render({
  lines = { "safe\r\ncontent" },
  width = 80,
  height = 1,
})
local guarded = captured.lines[1]

return table.concat({
  rt._debug_sanitize_terminal_text("alpha\r\nbeta\rgamma", true):gsub("\n", "|"),
  table.concat(rendered, "|"):gsub("\27%[[%d;]*m", ""),
  edited.input:gsub("\n", "|"),
  tostring(#edited.rendered),
  tostring(tool.output_line_count("old\rnew\r\nnext")),
  guarded:gsub("\27%][^\7]*\7", ""):gsub("\27%[[%d;]*m", ""),
  tostring(guarded:find("\r", 1, true) == nil and guarded:find("\n", 1, true) == nil),
}, "|")
