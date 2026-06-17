--[==[psi-test
expect = "true|done|0"
]==]
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local pidfile = os.tmpname()
local command = "printf done; (sleep 5) & echo $! > " .. shell_quote(pidfile)
local h = assert(psi.process_begin(command))
local done = false

for _ = 1, 20 do
  local _, is_done = psi.process_poll(h, 25)
  if is_done then
    done = true
    break
  end
end

local r = psi.process_finish(h)
local f = io.open(pidfile, "r")
local pid = f and f:read("*l") or nil
if f then f:close() end
os.remove(pidfile)
if pid and pid:match("^%d+$") then
  os.execute("kill " .. pid .. " >/dev/null 2>&1")
end

return tostring(done) .. "|" .. r.output .. "|" .. tostring(r.status)
