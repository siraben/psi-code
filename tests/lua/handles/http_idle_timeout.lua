--[==[psi-test
expect = "true|true"

[env]
PSI_HTTP_CONNECT_TIMEOUT_MS = "1000"
PSI_HTTP_IDLE_TIMEOUT_MS = "1000"
]==]
local script = TMP .. "/stall_http.py"
local f = assert(io.open(script, "w"))
f:write([[
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(5)

    def do_POST(self):
        time.sleep(5)

    def log_message(self, fmt, *args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
]])
f:close()

local proc, err = psi.process_begin_argv({ "python3", "-u", script })
if not proc then
  return tostring(err)
end

local output = ""
local port = nil
for _ = 1, 100 do
  local chunk, done = psi.process_poll(proc, 50)
  if chunk then
    output = output .. chunk
    port = output:match("(%d+)")
    if port then
      break
    end
  end
  if done then
    break
  end
end

if not port then
  psi.process_terminate(proc)
  psi.process_finish(proc)
  return "no-port:" .. output
end

local url = "http://127.0.0.1:" .. port .. "/"
local status, get_err = psi.http_get(url, {})
local get_timed_out = status == nil and tostring(get_err):lower():find("slow", 1, true) ~= nil

local stream_timed_out = false
local handle, begin_err = psi.http_stream_begin(url, {}, "x")
if handle then
  for _ = 1, 100 do
    local _, done = psi.http_stream_poll(handle, 50)
    if done then
      break
    end
  end
  local stream_status, stream_err = psi.http_stream_finish(handle)
  stream_timed_out = stream_status == -1
    and tostring(stream_err):lower():find("slow", 1, true) ~= nil
else
  stream_timed_out = tostring(begin_err):lower():find("slow", 1, true) ~= nil
end

psi.process_terminate(proc)
psi.process_finish(proc)

return tostring(get_timed_out) .. "|" .. tostring(stream_timed_out)
