--[==[psi-test
expect = "32|true"
]==]
local queue = require("psi.file_mutation_queue")
local sched = require("psi.sched")

local order = {}
local tasks = {}
for i = 1, 32 do
  tasks[i] = function()
    queue.with_path(TMP .. "/shared.txt", function()
      order[#order + 1] = i
      sched.sleep_ms(1)
    end)
  end
end

sched.run(function()
  sched.run_all(tasks)
end)

local ordered = true
for i = 1, #order do
  if order[i] ~= i then
    ordered = false
    break
  end
end
return tostring(#order) .. "|" .. tostring(ordered)
