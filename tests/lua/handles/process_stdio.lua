--[==[psi-test
expect = "reply:hello|0"
]==]
local h, err = psi.process_begin_stdio_argv({
  "sh",
  "-c",
  "read line; printf 'reply:%s\\n' \"$line\"",
})
if not h then
  return err
end
local ok, werr = psi.process_write(h, "hello\n")
if not ok then
  return werr
end
psi.process_close_stdin(h)
while true do
  local _, done = psi.process_poll(h, 50)
  if done then
    break
  end
end
local r = psi.process_finish(h)
return r.output:gsub("%s+$", "") .. "|" .. tostring(r.status)
