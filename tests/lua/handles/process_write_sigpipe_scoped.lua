--[==[psi-test
expect = "sigpipe-default"
]==]
local marker = TMP .. "/sigpipe-survived"
local h, err = psi.process_begin_stdio_argv({ "sh", "-c", "exit 0" })
if not h then
  return err
end
while true do
  local _, done = psi.process_poll(h, 10)
  if done then
    break
  end
end
psi.process_write(h, string.rep("x", 4096))
psi.process_finish(h)
os.remove(marker)
os.execute("sh -c 'kill -PIPE $$; echo survived > " .. marker .. "'")
local f = io.open(marker, "r")
if f then
  f:close()
  return "sigpipe-ignored"
end
return "sigpipe-default"
