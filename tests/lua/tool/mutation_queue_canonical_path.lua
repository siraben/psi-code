--[==[psi-test
expect = "real start|real end|link start|link end"
]==]
local sched = require("psi.sched")
local queue = require("psi.file_mutation_queue")

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local real_dir = TMP .. "/real"
local link_dir = TMP .. "/link"
assert(psi.mkdir_p(real_dir))
os.execute("ln -s " .. shell_quote(real_dir) .. " " .. shell_quote(link_dir))

local order = {}
local function locked(label, path)
  return function()
    queue.with_path(path, function()
      order[#order + 1] = label .. " start"
      sched.sleep_ms(1)
      order[#order + 1] = label .. " end"
    end)
  end
end

sched.run(function()
  sched.run_all({
    locked("real", real_dir .. "/file.txt"),
    locked("link", link_dir .. "/file.txt"),
  })
end)

return table.concat(order, "|")
