#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PSI="$ROOT_DIR/build/psi"
TMP_DIR=$(mktemp -d)
SESSION_FILE="$TMP_DIR/session.jsonl"
TOOL_FILE="$TMP_DIR/tool.txt"
CONTEXT_DIR="$TMP_DIR/project"

trap 'rm -rf "$TMP_DIR"' EXIT

# ----------------------------------------------------------------------
# Lua eval surface: basic arithmetic, host primitives, and module access.
# ----------------------------------------------------------------------
"$PSI" --eval 'return 1 + 2 + 3' | grep '^6$'
"$PSI" --eval 'return #psi.read_file("README.md") > 0 and "ok" or "bad"' | grep '^ok$'
"$PSI" --eval 'return require("psi.tools").all()[1].name' | grep '^read$'

# ----------------------------------------------------------------------
# Tool dispatch: each built-in tool produces an ok ToolResult with the
# right `tool` field and expected side effects.
# ----------------------------------------------------------------------
"$PSI" --eval 'local r = require("psi.tools").dispatch("read", {path="README.md"}); return r.tool .. " " .. tostring(r.ok)' \
    | grep '^read true$'

"$PSI" --eval "local r = require('psi.tools').dispatch('write', {path='$TOOL_FILE', content='alpha beta'}); return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.bytes_written)" \
    | grep '^write true 10$'
grep '^alpha beta$' "$TOOL_FILE"

"$PSI" --eval "local r = require('psi.tools').dispatch('edit', {path='$TOOL_FILE', oldText='beta', newText='gamma'}); return r.tool .. ' ' .. tostring(r.ok) .. ' ' .. tostring(r.extras.replacements)" \
    | grep '^edit true 1$'
grep '^alpha gamma$' "$TOOL_FILE"

"$PSI" --eval 'local r = require("psi.tools").dispatch("bash", {command="printf hello"}); return r.extras.output' \
    | grep '^hello$'

"$PSI" --eval "local r = require('psi.tools').dispatch('grep', {pattern='alpha gamma', path='$TOOL_FILE', literal=true}); return r.tool .. ' ' .. tostring(r.ok)" \
    | grep '^grep true$'

"$PSI" --eval 'local r = require("psi.tools").dispatch("find", {pattern="*.md", path=".", limit=5}); return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)' \
    | grep '^find true true$'

"$PSI" --eval 'local r = require("psi.tools").dispatch("ls", {path=".", limit=5}); return r.tool .. " " .. tostring(r.ok) .. " " .. tostring(#r.extras.output > 0)' \
    | grep '^ls true true$'

"$PSI" --eval 'local r = require("psi.tools").dispatch("lua", {mode="summary"}); return r.extras.result:match("psi Lua runtime")' \
    | grep '^psi Lua runtime$'

"$PSI" --eval 'local r = require("psi.tools").dispatch("lua", {mode="eval", expression="#require(\"psi.tools\").all()"}); return r.extras.result' \
    | grep '^8$'

# ----------------------------------------------------------------------
# Render event hooks: tool-call captures a frame, tool-result renders a
# diff. Exercises psi.render.handle_event on the write tool.
# ----------------------------------------------------------------------
"$PSI" --eval "
local tools = require('psi.tools')
local render = require('psi.render')
render.handle_event('tool-call', {id='w1', tool='write', input={path='$TOOL_FILE', content='delta'}})
local r = tools.dispatch('write', {path='$TOOL_FILE', content='delta'})
return render.handle_event('tool-result', {id='w1', tool='write', result=r})
" | grep 'updated'

"$PSI" --eval "
local tools = require('psi.tools')
local render = require('psi.render')
render.handle_event('tool-call', {id='w2', tool='write', input={path='$TOOL_FILE', content='delta'}})
local r = tools.dispatch('write', {path='$TOOL_FILE', content='delta'})
return render.handle_event('tool-result', {id='w2', tool='write', result=r})
" | grep 'delta'

# ----------------------------------------------------------------------
# System prompt: lists the tools, picks up AGENTS.md context files.
# ----------------------------------------------------------------------
"$PSI" --system-prompt | grep '^Available tools:$'
"$PSI" --system-prompt | grep 'lua: Inspect or evaluate the embedded Lua runtime'
"$PSI" --help | grep -- '--tui'

mkdir -p "$CONTEXT_DIR"
printf '%s\n' 'Project rule: keep changes minimal.' >"$CONTEXT_DIR/AGENTS.md"
(cd "$CONTEXT_DIR" && "$PSI" --system-prompt) | grep 'Project rule: keep changes minimal.'

# ----------------------------------------------------------------------
# Print and TUI modes: non-session and session round-trip.
# ----------------------------------------------------------------------
"$PSI" --print 'hello' | grep 'prompt: hello'
"$PSI" --print 'hello' | grep 'session-messages: 1'
printf ':quit\n' | "$PSI" >/dev/null
if command -v script >/dev/null 2>&1; then
    printf '/quit\n' | script -qec "$PSI --tui" /dev/null >/dev/null
fi

"$PSI" --session "$SESSION_FILE" --print 'one' >/dev/null
"$PSI" --session "$SESSION_FILE" --print 'two' | grep 'session-messages: 3'
grep '"type":"session"' "$SESSION_FILE"
test "$(grep -c '"type":"message"' "$SESSION_FILE")" -eq 4
grep '"text":"two"' "$SESSION_FILE"

# ----------------------------------------------------------------------
# Optional: live Anthropic turn when a key is available. Uses the same
# coding-agent surface the TUI and --agent flag would exercise.
# ----------------------------------------------------------------------
if [ "${ANTHROPIC_API_KEY:-}" != "" ]; then
    AGENT_SESSION="$TMP_DIR/agent-session.jsonl"
    # Default to claude-haiku-4-5 for the tool-dispatch suite —
    # it's cheap and consistently invokes the requested tools.
    # Callers can override with PSI_ANTHROPIC_MODEL for broader
    # model-version sweeps.
    MODEL="${PSI_ANTHROPIC_MODEL:-claude-haiku-4-5}"
    "$PSI" --agent 'Say exactly: psi live agent smoke' --model "$MODEL" --max-tokens 32 \
        | grep 'psi live agent smoke'
    "$PSI" --session "$AGENT_SESSION" \
        --agent 'Use the bash tool to run exactly: echo tool-smoke-ok. Then reply with exactly: tool smoke ok' \
        --model "$MODEL" --max-tokens 200 | grep 'tool smoke ok'
    "$PSI" --session "$AGENT_SESSION" --agent 'Reply with exactly: second turn ok' \
        --model "$MODEL" --max-tokens 64 | grep 'second turn ok'
    # v2 JSONL session schema (pi-compatible). Tool calls are
    # nested inside the assistant message's content array as
    # {"type":"toolCall",...}; the top-level "role" values are
    # camelCase, and a compaction rewrite leaves a standalone
    # {"type":"compaction",...} header entry.
    grep '"type":"toolCall"' "$AGENT_SESSION"
    grep '"role":"toolResult"' "$AGENT_SESSION"
    "$PSI" --session "$AGENT_SESSION" --compact 4 --model "$MODEL" --max-tokens 256 | grep .
    grep '"type":"compaction"' "$AGENT_SESSION"

    # ------------------------------------------------------------------
    # Concurrent tool dispatch: when Claude emits multiple tool_use
    # blocks in a single assistant turn, psi must run them in parallel,
    # not serialise them. We prompt for three shell commands whose
    # combined serial time (3+6+9 = 18s) is much larger than the max
    # (9s); wall time should be closer to the max than the sum.
    # Budget 25s to absorb round-trip latency + auto-compaction.
    # ------------------------------------------------------------------
    PARALLEL_SESSION="$TMP_DIR/parallel-session.jsonl"
    PARALLEL_OUT="$TMP_DIR/parallel-out"
    START=$(date +%s)
    "$PSI" --session "$PARALLEL_SESSION" \
        --agent 'Issue three separate bash tool calls in this same turn, all at once. The three commands are exactly: "sleep 3 && echo apple", "sleep 6 && echo banana", "sleep 9 && echo cherry". Do not chain them with &&, do not background them with &, do not combine them — emit three distinct tool_use blocks. After the tools run, reply with exactly: parallel done' \
        --model claude-haiku-4-5 --max-tokens 500 > "$PARALLEL_OUT"
    END=$(date +%s)
    ELAPSED=$((END - START))

    # Acceptance: all three tool invocations ran (each echoed fruit
    # appears in the persisted session)
    grep apple  "$PARALLEL_SESSION" >/dev/null
    grep banana "$PARALLEL_SESSION" >/dev/null
    grep cherry "$PARALLEL_SESSION" >/dev/null

    # Acceptance: wall time is closer to the max (9s) than the sum
    # (18s). Threshold at 15s leaves room for network + compaction
    # overhead without letting a silent regression back to serial
    # dispatch slip through. On a typical link the actual number is
    # around 10-11s.
    if [ "$ELAPSED" -gt 15 ]; then
        echo "concurrent-tool smoke FAIL: elapsed=${ELAPSED}s (expected <=15s, sum-serial would be ~18s)" >&2
        exit 1
    fi
    echo "concurrent-tool smoke ok (${ELAPSED}s)"
fi
