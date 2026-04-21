# Providers

psi currently ships with two providers: Anthropic (the default, via
`https://api.anthropic.com`) and Ollama (local, via `/api/chat`).

The chosen provider drives a single `run_turn` / `complete_text`
contract, so sessions are provider-neutral on disk — a session started
with one provider can be resumed with the other, provided the tool
names line up. Cross-provider resumes are best-effort: Anthropic stores
`cache_control` breakpoints that Ollama ignores, and Ollama doesn't
distinguish `stopReason="maxTokens"` from `"stop"`.

## Selection

In priority order:

1. **Model prefix** — `--model=ollama/llama3.1:latest` or
   `--model=anthropic/claude-sonnet-4-6`. The prefix is stripped before
   being forwarded to the provider.
2. **`PSI_PROVIDER`** env var — `anthropic` (default) or `ollama`.
3. Fallback: Anthropic with whatever `--model` you passed.

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

## Examples

```bash
# Anthropic (default)
psi --session=s.jsonl --model=claude-sonnet-4-6 --agent="..."

# Ollama local
psi --session=s.jsonl --model=ollama/llama3.1:latest --agent="..."

# Ollama via env default
PSI_PROVIDER=ollama PSI_OLLAMA_MODEL=llama3.2 psi --agent="..."

# Ollama on a remote box
PSI_OLLAMA_BASE_URL=http://workstation.local:11434 \
  psi --model=ollama/llama3.1 --agent="..."
```

## Not yet supported

- Provider registration from extensions (see `docs/extensions.md`
  non-goals). Providers are a core concern today.
- OpenAI, Bedrock, Gemini — pi has these; psi does not.
- Model-specific context-window / pricing metadata is only defined for
  the Claude 4.x family in `lua/psi/context.lua`. Ollama models fall
  back to the 128k default window regardless of actual capacity.
