--[[psi-test
expect = "2:fast,1:slow|slow|fast"
]]
local sched = require("psi.sched")
local seen = {}
local results = sched.run_all({
  function() sched.sleep_ms(20); return "slow" end,
  function() return "fast" end,
}, { on_done = function(i, r)
  seen[#seen + 1] = tostring(i) .. ":" .. tostring(r.values and r.values[1])
end })
return table.concat(seen, ",") .. "|"
  .. results[1].values[1] .. "|" .. results[2].values[1]
