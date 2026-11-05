# MCP over Streamable HTTP

psi includes a small JSON-RPC client for MCP tool servers using the
[2025-11-25 Streamable HTTP
transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
It uses the same asynchronous libcurl boundary and cooperative Lua scheduler as
provider traffic. Protocol policy remains in `lua/psi/mcp.lua`.

## Configuration

Add servers to `mcp.servers` in `~/.config/psi/settings.json` or
`./.psi/settings.json`. Project settings override and merge with global
settings by server key.

```json
{
  "mcp": {
    "servers": {
      "inventory": {
        "transport": "http",
        "url": "https://inventory.example.test/mcp",
        "timeout_ms": 30000,
        "tool_prefix": "inventory",
        "headers": {
          "Authorization": "Bearer ${INVENTORY_MCP_TOKEN}"
        }
      }
    }
  }
}
```

Fields:

- `transport`: optional; `"http"` or `"streamable-http"`. No other transport
  is accepted.
- `url`: required `http://` or `https://` MCP endpoint.
- `timeout_ms`: integer deadline from `1` through `2147483647` milliseconds for
  each initialize, discovery, or tool-call request; default `30000`.
- `tool_prefix`: optional local tool-name prefix; defaults to the server key.
- `headers`: optional string map. Values support `$VAR`, `${VAR}`, and
  `!command` resolution through the same credential resolver as provider API
  keys. Protocol-owned headers cannot be overridden.
- `enabled`: set to `false` to disable a server inherited from global settings.

Project-local settings are trusted code/configuration: an MCP endpoint can see
the arguments sent to its tools and can return model-visible content. Review
the endpoint and headers before running psi in an unfamiliar repository. For
local servers, bind to `127.0.0.1`, not `0.0.0.0`; use authentication for any
endpoint reachable by other hosts.

## Lifecycle and tools

At boot, each enabled server is initialized with protocol version
`2025-11-25` and empty client capabilities. psi accepts negotiated Streamable
HTTP versions `2025-11-25`, `2025-06-18`, and `2025-03-26`. A server must
advertise the `tools` capability before psi sends `tools/list`.

After initialization psi sends `notifications/initialized`, follows every
`nextCursor` from `tools/list`, and registers each discovered tool in the shared
tool registry. A server key `inventory` with remote tool `lookup-item` becomes
`inventory_lookup-item` by default. Unsupported characters are replaced with
underscores and names longer than 64 characters receive a deterministic hash
suffix. Collisions fail that server's registration instead of overwriting an
existing tool.

MCP tools use sequential execution mode. This keeps one server's negotiated
session and 404 recovery coherent when a model emits multiple calls together.
Calls preserve MCP `content`, `structuredContent`, and `isError` in psi's
structured `ToolResult`; text content is also exposed as `output`.

If initialization returns `MCP-Session-Id`, psi sends it with every subsequent
request. HTTP 404 for that session triggers one fresh initialize handshake and
one retry. On normal session shutdown (and through `psi.mcp.close_all()`), psi
sends a bounded best-effort HTTP DELETE; HTTP 405 is accepted for servers that
do not implement client-initiated termination.

`close_all()` and `/reload` close existing MCP sessions and remove the remote
tools they still own. `/reload` then reloads settings and initializes the new
server set. If an extension deliberately replaced a remote tool with the same
name, MCP teardown leaves that replacement intact.

## Errors, timeouts, and abort

The client API returns structured errors with a `kind` and `message`. Kinds are
`config`, `capability`, `closed`, `transport`, `timeout`, `aborted`, `http`,
`protocol`, and `rpc`; relevant records also carry fields such as HTTP status,
JSON-RPC code/data, curl transport code, or timeout duration.

Every request has a libcurl-enforced total deadline. During a normal tool call,
timeouts also cause a bounded best-effort `notifications/cancelled` message.
Ctrl-C/Escape uses psi's shared abort signal, so a blocked MCP HTTP transfer
terminates through the same path as provider traffic.

Configured MCP startup failures are written to stderr and do not prevent psi
from starting. Inspect `psi.mcp.status()` for the per-server result.

## Lua API

`psi.mcp.new_client(config)` returns a client (or `nil, error`) with:

- `initialize()`
- `request(method, params)` and `notify(method, params)`
- `list_tools()` and `call_tool(name, arguments)`
- `close()`

The shared configured-client manager exposes:

- `psi.mcp.bootstrap()` / `reload()` / `close_all()`
- `psi.mcp.clients()`
- `psi.mcp.status()`

## Deliberate limits

The bundled transport covers POST-delivered JSON responses and POST-delivered
SSE streams, which are sufficient for initialization, discovery, and tool
calls. It handles server notifications on those streams and answers `ping`
requests (other server requests receive JSON-RPC `Method not found`).

It does not currently implement standalone GET event streams, SSE resumption
with `Last-Event-ID`, the deprecated HTTP+SSE compatibility transport, OAuth
discovery, tasks, resources, prompts, sampling, elicitation, or a stdio MCP
client. Tool-list change notifications are retained for inspection but do not
automatically refresh registrations; use `/reload` to rediscover tools. The
`MCP` build flag only gates low-level stdio process primitives; it must not be
read as bundled stdio protocol support. Streamable HTTP support is available
because libcurl is already a required psi dependency.
