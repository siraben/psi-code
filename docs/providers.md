# Providers

psi ships with four routed providers:

- Anthropic, the default, via `https://api.anthropic.com`
- Ollama, local, via `/api/chat`
- OpenRouter, via OpenAI-compatible `/chat/completions`
- OpenAI Codex, via ChatGPT's Codex Responses backend

For default models and environment-variable mappings, ask the running agent.
Runtime introspection stays accurate after provider registry changes:

```
psi> /apropos provider:
psi> /describe provider:openai-codex
```

Providers implement a shared `run_turn` / `complete_text` contract, so sessions
are provider-neutral on disk. A session started with one provider can be resumed
with another as long as the tool names line up. Cross-provider resumes are
best-effort: provider-specific thinking, signature, and cache details may be
downgraded during replay.

Routing metadata lives in `lua/psi/api_registry.lua`. API-specific wire
adapters live in `lua/psi/providers/anthropic.lua`,
`lua/psi/providers/openai_compat.lua`, `lua/psi/providers/openrouter.lua`,
`lua/psi/providers/openai_codex.lua`, and `lua/psi/providers/ollama.lua`.

## Selection

In priority order:

1. **Model prefix:** `--model=ollama/llama3.1:latest` or
   `--model=anthropic/claude-sonnet-4-6` or
   `--model=openrouter/google/gemini-3-flash-preview` or
   `--model=openai-codex/gpt-5.5`. The prefix is stripped before being
   forwarded to the provider.
2. **`PSI_PROVIDER` env var:** `anthropic` (default), `ollama`, or
   `openrouter`, or `openai-codex`.
3. **Settings:** `defaults.provider` and `defaults.model` in
   `~/.config/psi/settings.json` or `./.psi/settings.json`.
4. Fallback: Anthropic.

## Streaming Retries

Streaming provider requests retry transient failures until assistant content or
a tool call has been parsed. This covers transport failures such as an empty
HTTP reply and retryable 429/5xx provider responses. Once a stream has produced
assistant or tool partials, psi records the failure instead of replaying the
request because provider streams are not resumable at that point.

- `PSI_HTTP_MAX_RETRIES`: maximum retry attempts after the first request
  (default `2`; set `0` to disable).
- `PSI_HTTP_RETRY_DELAY_MS`: initial exponential-backoff delay
  (default `1000`).
- `PSI_HTTP_MAX_RETRY_DELAY_MS`: cap for retry sleep (default `60000`).

## HTTP Timeouts

All provider HTTP calls share curl-level stall protection. The defaults
allow long model streams but fail silent network paths so the agent can
surface a transport error or retry at the provider layer.

- `PSI_HTTP_CONNECT_TIMEOUT_MS` — TCP/TLS connect timeout
  (default `15000`; set `0` to disable).
- `PSI_HTTP_IDLE_TIMEOUT_MS` — low-speed idle timeout for header/body
  stalls (default `300000`; set `0` to disable).
- `PSI_HTTP_TOTAL_TIMEOUT_MS` — optional total request deadline
  (default disabled; useful for short metadata requests, risky for
  long streaming turns).

## API-key credentials (auth.json)

API-key providers read their key from `~/.config/psi/auth.json` in addition to
the environment variable, matching pi-mono's credential handling. The
**auth-file entry takes precedence over the environment variable**.

Each provider is keyed by its provider name (`anthropic`, `openrouter`, …):

```json
{
  "openrouter": { "type": "api_key", "key": "sk-or-..." },
  "anthropic":  { "type": "api_key", "key": "${WORK_ANTHROPIC_KEY}" }
}
```

The `key` field is resolved at use time:

- **Literal** — used verbatim (`"sk-or-..."`).
- **`$VAR` / `${VAR}`** — substituted from the process environment; embedded
  references (`"pre-${VAR}-post"`) are interpolated too. An unset variable
  collapses to empty.
- **`!shell-command`** — the command after `!` is run and its trimmed stdout
  becomes the key. Results are cached per psi process, so a command that mints a
  short-lived token runs at most once per session.

The file is written with mode `0600` (see OpenAI Codex below). `PSI_AUTH_FILE`
overrides its path. OpenAI Codex OAuth credentials live in the same file under
the `openai-codex` key and are unaffected by this API-key resolution.

## Anthropic

- Auth: `ANTHROPIC_API_KEY`, or an `anthropic` api_key entry in `auth.json`
  (see [API-key credentials](#api-key-credentials-authjson); auth file wins).
- `PSI_ANTHROPIC_MODEL`: default model when none is passed (default
  `claude-opus-4-7`).
- `PSI_ANTHROPIC_BASE_URL`: override the API host (for proxies).
- `PSI_PROMPT_CACHE=0` disables ephemeral prompt caching.
- Image attachments are enabled by default for image-capable providers and
  models. Set `"images": { "block_images": true }` in
  `~/.config/psi/settings.json` or `./.psi/settings.json` to omit image
  blocks before provider requests. Psi does not auto-resize oversized images;
  the read tool omits images that exceed its inline payload limit.

## Ollama

- No API key.
- Requires an Ollama daemon reachable at `PSI_OLLAMA_BASE_URL`
  (default `http://localhost:11434/`).
- `PSI_OLLAMA_MODEL`: default model when none is passed (default
  `llama3.1:latest`).
- Tool use requires a model that Ollama advertises as tool-capable
  (e.g. llama3.1, llama3.2, qwen2.5). Non-tool models work for chat
  but the agent loop will never fire tool calls.
- Usage totals are translated to the normalized session shape
  (`usage.input = prompt_eval_count`, `usage.output = eval_count`).
- No prompt caching on the wire. Ollama does not support it.

## OpenRouter

- Auth: `OPENROUTER_API_KEY`, or an `openrouter` api_key entry in `auth.json`
  (see [API-key credentials](#api-key-credentials-authjson); auth file wins).
- `PSI_OPENROUTER_MODEL`: default model when none is passed
  (default `google/gemini-3-flash-preview`).
- `PSI_OPENROUTER_BASE_URL`: override the API host.
- Optional attribution:
  - `PSI_OPENROUTER_REFERER`
  - `PSI_OPENROUTER_TITLE`
- Uses the shared OpenAI-compatible adapter in
  `lua/psi/providers/openai_compat.lua`.

## OpenAI Codex

- Auth: `/login openai-codex`, open the printed URL, then paste the final
  redirect URL or authorization code back with `/login openai-codex
  <redirect-url-or-code>`. When terminal clipboard support is enabled, the auth
  URL is also copied through OSC 52. Credentials are stored in
  `~/.config/psi/auth.json` with mode `0600` when `chmod` is available.
- `PSI_AUTH_FILE`: override the credential file path.
- `PSI_OPENAI_CODEX_MODEL`: default model when none is passed (default
  `gpt-5.5`).
- `PSI_OPENAI_CODEX_BASE_URL`: override the ChatGPT backend host.
- Thinking/reasoning level follows pi-mono naming:
  `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. The default is
  `medium`; `off`/`none` omits the reasoning block. Use
  `--thinking <level>` at startup or `/thinking <level>` inside a
  session. `/set effort <off|minimal|low|medium|high|xhigh|none>` is
  also accepted for compatibility with the lower-level setting name.
  `minimal` is sent as `low` for current OpenAI Codex models.
- `PSI_THINKING`: optional global default thinking level.
- `PSI_OPENAI_CODEX_REASONING`: optional legacy Codex-specific
  default. For a config default, set `defaults.reasoning_effort` in
  `~/.config/psi/settings.json` or `./.psi/settings.json`.
- `PSI_OPENAI_CODEX_VERBOSITY`: optional text verbosity
  (`low`, `medium`, `high`; default `low`).
- Uses the Responses-shaped adapter in `lua/psi/providers/openai_codex.lua`.

## Examples

```bash
# Anthropic (default)
psi --session=s.jsonl --model=claude-sonnet-4-6 --agent="..."

# Ollama local
psi --session=s.jsonl --model=ollama/llama3.1:latest --agent="..."

# Ollama via env default
PSI_PROVIDER=ollama PSI_OLLAMA_MODEL=llama3.2 psi --agent="..."

# OpenRouter
OPENROUTER_API_KEY=... \
  psi --model=openrouter/google/gemini-3-flash-preview --agent="..."

# OpenAI Codex
psi
psi> /login openai-codex
psi> /login openai-codex http://localhost:1455/auth/callback?code=...&state=...
psi> /model openai-codex/gpt-5.5
psi> /thinking xhigh

# Ollama on a remote box
PSI_OLLAMA_BASE_URL=http://workstation.local:11434 \
  psi --model=ollama/llama3.1 --agent="..."
```

## Not yet supported

- Provider registration from extensions. The registry exists in Lua,
  but public extension APIs for adding providers are not frozen yet.
- Bedrock, Gemini native, Mistral native, and Azure responses.
- Browser callback completion for OAuth. OpenAI Codex uses the same manual paste
  fallback that pi-mono supports for headless sessions.
- Full pricing metadata. OpenRouter context-window and output-token
  metadata is cached lazily as JSON under the user cache directory; the
  first lookup for a missing OpenRouter model refreshes the cache from
  OpenRouter's `/api/v1/models` endpoint.
