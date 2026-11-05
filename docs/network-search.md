# Optional network search extension

psi includes an inspectable Lua reference extension for network search. It is
disabled by default, registers no tool and performs no network or credential
work until explicitly enabled, adds no dependency, and does not require MCP.
All provider policy lives in `lua/psi/extensions/network_search.lua` above the
existing HTTP, abort, settings, and credential primitives.

Enable Tavily in `~/.config/psi/settings.json` or `./.psi/settings.json`:

```json
{
  "extensions": {
    "network_search": {
      "enabled": true,
      "provider": "tavily"
    }
  }
}
```

Then put the credential in the environment:

```sh
export PSI_NETWORK_SEARCH_API_KEY=tvly-...
```

Or use psi's normal `auth.json` credential resolution under the
`network-search` key:

```json
{
  "network-search": {
    "type": "api_key",
    "key": "${TAVILY_API_KEY}"
  }
}
```

Auth-file values support the same literal, `$VAR` / `${VAR}`, and cached
`!shell-command` forms documented in [Providers](providers.md). The auth file
takes precedence over `PSI_NETWORK_SEARCH_API_KEY`. Credentials are sent only
in the provider's required request header and are never placed in tool results,
session records, endpoints, or extension logs.

Restart psi after enabling the extension. The model then receives a
`network_search` tool with this input:

```json
{ "query": "Lua 5.5 release notes", "count": 5 }
```

Successful results have a deliberately small, provider-neutral shape:

```json
{
  "ok": true,
  "tool": "network_search",
  "query": "Lua 5.5 release notes",
  "provider": "tavily",
  "count": 1,
  "sources": [
    {
      "source": "lua.org",
      "title": "Lua 5.5 reference manual",
      "snippet": "...",
      "url": "https://www.lua.org/manual/5.5/"
    }
  ]
}
```

Search snippets are untrusted provider summaries. The tool tells the model to
cite returned URLs and not treat snippets as authoritative page contents.

## Providers and endpoints

`extensions.network_search.provider` supports:

- `tavily` (default): `POST https://api.tavily.com/search`, with a Bearer token.
  The response adapter reads Tavily's `results` array.
- `generic`: a small JSON-over-HTTP reference contract for a local service or
  proxy. It posts `{ "query": "...", "limit": N }` and accepts either a
  `results` array, a `data` array, or `data.results`. Each row may use
  `url`/`link`, `title`/`name`, and
  `snippet`/`description`/`content`/`text`. The default endpoint is
  `http://127.0.0.1:8080/search`.

The built-in endpoint and auth scheme follow the official
[Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search).
Set `extensions.network_search.endpoint` or `PSI_NETWORK_SEARCH_ENDPOINT` to
use a compatible proxy. Endpoints must use HTTP(S), cannot contain userinfo,
and must not carry credentials in their URL.

Generic endpoints require the configured credential by default and receive it
as `Authorization: Bearer ...`. For an unauthenticated loopback service only,
set `"require_credential": false`.

## Configuration and limits

Environment overrides:

- `PSI_NETWORK_SEARCH_ENABLED=1`
- `PSI_NETWORK_SEARCH_PROVIDER=tavily|generic`
- `PSI_NETWORK_SEARCH_ENDPOINT=https://...`
- `PSI_NETWORK_SEARCH_API_KEY=...`

Settings under `extensions.network_search`:

- `auth_provider` (default `network-search`) selects the `auth.json` key.
- `credential_env` (default `PSI_NETWORK_SEARCH_API_KEY`) selects the fallback
  environment variable.
- `max_query_bytes` defaults to 512 and has an absolute cap of 2048.
- `max_results` defaults to 8 and is capped at 10 for Tavily and 20 otherwise.
- `max_response_bytes` defaults to 512 KiB and has an absolute cap of 2 MiB.
- `max_title_bytes` defaults to 200 and is capped at 300.
- `max_snippet_bytes` defaults to 1200 and is capped at 4000.

Queries and result fields are validated, control characters are removed,
duplicate or non-HTTP(S) URLs are dropped, and response JSON is decoded only
after the byte limit check. Any effective credential echoed in a response field
is removed before the result reaches the model or session. Transport errors
never echo request headers, provider response bodies, credentials, or configured
endpoints.

Timeouts use psi's shared curl controls:

- `PSI_HTTP_CONNECT_TIMEOUT_MS`
- `PSI_HTTP_IDLE_TIMEOUT_MS`
- `PSI_HTTP_TOTAL_TIMEOUT_MS`

Timeout, abort, authentication, rate-limit, provider, malformed-response, and
oversized-response cases return short model-visible failures. Tavily and generic
POST requests use psi's cooperative streaming handle when called inside the
agent scheduler, sharing the host abort signal and curl timeout enforcement.

Inspect the exact running implementation without locating installation files:

```text
psi> /lua return psi.embedded_source("psi.extensions.network_search")
```
