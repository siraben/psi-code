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
    MODEL="${PSI_ANTHROPIC_MODEL:-claude-opus-4-7}"
    "$PSI" --agent 'Say exactly: psi live agent smoke' --model "$MODEL" --max-tokens 32 \
        | grep 'psi live agent smoke'
    "$PSI" --session "$AGENT_SESSION" --agent 'Read README.md and reply with exactly: tool smoke ok' \
        --model "$MODEL" --max-tokens 128 | grep 'tool smoke ok'
    "$PSI" --session "$AGENT_SESSION" --agent 'Reply with exactly: second turn ok' \
        --model "$MODEL" --max-tokens 64 | grep 'second turn ok'
    grep '"role":"tool-call"' "$AGENT_SESSION"
    grep '"role":"tool-result"' "$AGENT_SESSION"
    "$PSI" --session "$AGENT_SESSION" --compact 4 --model "$MODEL" --max-tokens 256 | grep .
    grep '"role":"compaction-summary"' "$AGENT_SESSION"
fi
