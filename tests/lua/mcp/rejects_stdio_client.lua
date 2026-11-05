--[==[psi-test
name = "mcp/rejects_stdio_client"
expect = "config|true"
]==]
local client, err = psi.mcp.new_client({ transport = "stdio", command = { "server" } })
return tostring(err.kind) .. "|" .. tostring(client == nil and err.message:find("not implemented", 1, true) ~= nil)
