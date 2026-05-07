--[==[psi-test
expect = "true|true|true|true"
]==]
local tool = require("psi.tui_components.tool_execution")
local records = require("psi.records")

local execution = tool.new({
  id = "toolu_debug",
  tool = "bash",
  input = { command = "printf hi" },
})

local first_generation = execution.box.generation
local first = execution:render(80)
local second_generation = execution.box.generation
local second = execution:render(80)

execution:set_result(records.tool_result_from_alist({ ok = true, output = "hi\n" }), false)
local third = execution:render(80)

return table.concat({
  tostring(first == second),
  tostring(first_generation == second_generation),
  tostring(third ~= second),
  tostring(execution.box.generation > second_generation),
}, "|")
