#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
SESSION_FILE="$TMP_DIR/session.jsonl"
TOOL_FILE="$TMP_DIR/tool.txt"
CONTEXT_DIR="$TMP_DIR/project"

trap 'rm -rf "$TMP_DIR"' EXIT

"$ROOT_DIR/build/psi" --eval '(+ 1 2 3)' | grep '^6$'
"$ROOT_DIR/build/psi" --eval '(if (> (string-length (psi-read-file "README.md")) 0) "ok" "bad")' | grep '^ok$'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "read" "{\"path\":\"README.md\"}")' | grep '"tool":"read"'
"$ROOT_DIR/build/psi" --eval "(psi-tool-call \"write\" \"{\\\"path\\\":\\\"$TOOL_FILE\\\",\\\"text\\\":\\\"alpha beta\\\"}\")" | grep '"tool":"write"'
grep '^alpha beta$' "$TOOL_FILE"
"$ROOT_DIR/build/psi" --eval "(psi-tool-call \"edit\" \"{\\\"path\\\":\\\"$TOOL_FILE\\\",\\\"oldText\\\":\\\"beta\\\",\\\"newText\\\":\\\"gamma\\\"}\")" | grep '"tool":"edit"'
grep '^alpha gamma$' "$TOOL_FILE"
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "bash" "{\"command\":\"true\"}")' | grep '"tool":"bash"'
"$ROOT_DIR/build/psi" --system-prompt | grep '^Available tools:$'
mkdir -p "$CONTEXT_DIR"
printf '%s\n' 'Project rule: keep changes minimal.' >"$CONTEXT_DIR/AGENTS.md"
(cd "$CONTEXT_DIR" && "$ROOT_DIR/build/psi" --system-prompt) | grep 'Project rule: keep changes minimal.'
"$ROOT_DIR/build/psi" --print 'hello' | grep 'prompt: hello'
"$ROOT_DIR/build/psi" --print 'hello' | grep 'session-messages: 1'
printf ':quit\n' | "$ROOT_DIR/build/psi" >/dev/null
"$ROOT_DIR/build/psi" --session "$SESSION_FILE" --print 'one' >/dev/null
"$ROOT_DIR/build/psi" --session "$SESSION_FILE" --print 'two' | grep 'session-messages: 3'
grep '"type":"session"' "$SESSION_FILE"
test "$(grep -c '"type":"message"' "$SESSION_FILE")" -eq 4
grep '"text":"two"' "$SESSION_FILE"

if [ "${ANTHROPIC_API_KEY:-}" != "" ]; then
    AGENT_SESSION="$TMP_DIR/agent-session.jsonl"
    "$ROOT_DIR/build/psi" --agent 'Say exactly: psi live agent smoke' --model "${PSI_ANTHROPIC_MODEL:-claude-opus-4-7}" --max-tokens 32 | grep 'psi live agent smoke'
    "$ROOT_DIR/build/psi" --session "$AGENT_SESSION" --agent 'Read README.md and reply with exactly: tool smoke ok' --model "${PSI_ANTHROPIC_MODEL:-claude-opus-4-7}" --max-tokens 128 | grep 'tool smoke ok'
    grep '"role":"tool-call"' "$AGENT_SESSION"
    grep '"role":"tool-result"' "$AGENT_SESSION"
fi
