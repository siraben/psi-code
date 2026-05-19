--[==[psi-test
expect = "10,0,0|a|b"
]==]
local sched = require("psi.sched")
local old_sleep = sched.resolvers.sleep
local aborted = false
local waits = {}

sched.resolvers.sleep = function(req)
  waits[#waits + 1] = tostring(req.ms or 0)
  if #waits == 1 then
    aborted = true
  end
  return nil
end

local ok, results = pcall(function()
  return sched.run_all({
    function()
      sched.sleep_ms(100)
      sched.sleep_ms(100)
      return "a"
    end,
    function()
      sched.sleep_ms(100)
      return "b"
    end,
  }, {
    abort_check = function()
      return aborted
    end,
  })
end)
sched.resolvers.sleep = old_sleep
if not ok then
  error(results)
end

return table.concat(waits, ",")
  .. "|"
  .. tostring(results[1].values[1])
  .. "|"
  .. tostring(results[2].values[1])
