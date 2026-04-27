# Providers

psi currently ships with four routed providers:

- Anthropic, the default, via `https://api.anthropic.com`
- Ollama, local, via `/api/chat`
- OpenRouter, via OpenAI-compatible `/chat/completions`
- Codex, OpenAI Responses API via `/v1/responses` (the wire api the
  Codex CLI speaks)

The chosen provider drives a single `run_turn` / `complete_text`
contract, so sessions are provider-neutral on disk — a session started
with one provider can be resumed with another, provided the tool names
line up. Cross-provider resumes are best-effort: provider-specific
thinking/signature/cache details may be downgraded during replay.

Routing metadata lives in `lua/psi/providers.lua`. API-specific wire
adapters live in `lua/psi/anthropic.lua`, `lua/psi/openai_compat.lua`,
`lua/psi/openrouter.lua`, `lua/psi/ollama.lua`, and `lua/psi/codex.lua`.

## Selection

In priority order:

1. **Model prefix** — `--model=ollama/llama3.1:latest` or
   `--model=anthropic/claude-sonnet-4-6` or
   `--model=openrouter/google/gemini-3-flash-preview` or
   `--model=codex/gpt-5.1-codex`. The prefix is stripped before being
   forwarded to the provider.
2. **`PSI_PROVIDER`** env var — `anthropic` (default), `ollama`,
   `openrouter`, or `codex`.
3. **Settings** — `defaults.provider` and `defaults.model` in
   `~/.config/psi/settings.json` or `./.psi/settings.json`.
4. Fallback: Anthropic.

## Anthropic

- Env: `ANTHROPIC_API_KEY` (required)
- `PSI_ANTHROPIC_MODEL` — default model when none is passed (default
  `claude-opus-4-7`).
- `PSI_ANTHROPIC_BASE_URL` — override the API host (for proxies).
- `PSI_PROMPT_CACHE=0` disables ephemeral prompt caching.

## Ollama

- No API key.
- Requires an Ollama daemon reachable at `PSI_OLLAMA_BASE_URL`
  (default `http://localhost:11434/`).
- `PSI_OLLAMA_MODEL` — default model when none is passed (default
  `llama3.1:latest`).
- Tool use requires a model that Ollama advertises as tool-capable
  (e.g. llama3.1, llama3.2, qwen2.5). Non-tool models work for chat
  but the agent loop will never fire tool calls.
- Usage totals are translated to the normalized session shape
  (`usage.input = prompt_eval_count`, `usage.output = eval_count`).
- No prompt caching on the wire — Ollama doesn't support it.

## OpenRouter

- Env: `OPENROUTER_API_KEY` (required).
- `PSI_OPENROUTER_MODEL` — default model when none is passed
  (default `google/gemini-3-flash-preview`).
- `PSI_OPENROUTER_BASE_URL` — override the API host.
- Optional attribution:
  - `PSI_OPENROUTER_REFERER`
  - `PSI_OPENROUTER_TITLE`
- Uses the shared OpenAI-compatible adapter in
  `lua/psi/openai_compat.lua`.

## Codex (OpenAI Responses API)

The Codex provider talks the OpenAI Responses API
(`POST /v1/responses` with SSE) — the same wire format the `codex`
CLI uses. Tools are flat function items, input is a typed item list
(messages + `function_call` + `function_call_output`), and reasoning
models stream their thinking summaries back as separate SSE events.

- Auth (priority order):
  1. `OPENAI_API_KEY`
  2. `CODEX_API_KEY`
  3. `~/.codex/auth.json` (the codex CLI's stored ChatGPT login —
     either an `OPENAI_API_KEY` field or a `tokens.access_token`).
- `PSI_CODEX_MODEL` — default model when none is passed (default
  `gpt-5.1-codex`).
- `PSI_CODEX_BASE_URL` — override the API host (proxies / Azure).
- `PSI_CODEX_REASONING_EFFORT` — `minimal` | `low` | `medium` |
  `high`. Forwarded to `reasoning.effort`.
- `PSI_CODEX_REASONING_SUMMARY` — `auto` | `concise` | `detailed` |
  `none` (`none` omits the field; otherwise sets
  `reasoning.summary`).
- `parallel_tool_calls` is enabled by default.
- `store: false` is sent on every request: psi owns the transcript,
  so server-side response history is never accumulated.

Reasoning summary streams arrive on the `thinking-delta` event
alongside Anthropic's extended-thinking output. Cross-provider
replay drops thinking blocks (Responses-API reasoning items are
tied to a server-side response_id and cannot be reused).

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

# Codex (OpenAI Responses API)
OPENAI_API_KEY=... \
  psi --model=codex/gpt-5.1-codex --agent="..."

# Codex with reasoning effort
OPENAI_API_KEY=... PSI_CODEX_REASONING_EFFORT=high \
  psi --model=codex/gpt-5.5 --agent="..."

# Ollama on a remote box
PSI_OLLAMA_BASE_URL=http://workstation.local:11434 \
  psi --model=ollama/llama3.1 --agent="..."
```

## Not yet supported

- Provider registration from extensions. The registry exists in Lua,
  but public extension APIs for adding providers are not frozen yet.
- Bedrock, Gemini native, Mistral native, Azure responses, and OAuth
  flows from pi-mono.
- Full pricing metadata. OpenRouter context-window and output-token
  metadata is cached lazily as JSON under the user cache directory; the
  first lookup for a missing OpenRouter model refreshes the cache from
  OpenRouter's `/api/v1/models` endpoint.
