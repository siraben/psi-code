--[==[psi-test
expect = "2|true|warn:firs|4|info:seco|0|false"
]==]
local notice = require("psi.notice")
local queue = notice.new_queue({
  max_count = 2,
  max_bytes = 64,
  max_text = 4,
})

assert(queue:push({ level = "warn", text = "first-long", source = "one" }))
assert(queue:push({ level = "info", text = "second-long", source = "two" }))
assert(not queue:push({ level = "error", text = "overflow" }))

local records, overflow = queue:drain()
return table.concat({
  tostring(#records),
  tostring(overflow),
  records[1].level .. ":" .. records[1].text,
  tostring(#records[1].text),
  records[2].level .. ":" .. records[2].text,
  tostring(queue:count()),
  tostring(select(2, queue:drain())),
}, "|")
