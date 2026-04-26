# Providers

psi currently ships with three routed providers:

- Anthropic, the default, via `https://api.anthropic.com`
- Ollama, local, via `/api/chat`
- OpenRouter, via OpenAI-compatible `/chat/completions`

The chosen provider drives a single `run_turn` / `complete_text`
contract, so sessions are provider-neutral on disk — a session started
with one provider can be resumed with another, provided the tool names
line up. Cross-provider resumes are best-effort: provider-specific
thinking/signature/cache details may be downgraded during replay.

Routing metadata lives in `lua/psi/providers.lua`. API-specific wire
adapters live in `lua/psi/anthropic.lua`, `lua/psi/openai_compat.lua`,
`lua/psi/openrouter.lua`, and `lua/psi/ollama.lua`.

## Selection

In priority order:

1. **Model prefix** — `--model=ollama/llama3.1:latest` or
   `--model=anthropic/claude-sonnet-4-6` or
   `--model=openrouter/google/gemini-3-flash-preview`. The prefix is
   stripped before being forwarded to the provider.
2. **`PSI_PROVIDER`** env var — `anthropic` (default), `ollama`, or
   `openrouter`.
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
