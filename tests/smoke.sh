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
"$ROOT_DIR/build/psi" --eval '(assq '"'"'name (car (psi-tool-specs)))' | grep 'read'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "read" (list (cons '"'"'path "README.md")))' | grep '(tool . "read")'
"$ROOT_DIR/build/psi" --eval "(psi-tool-call \"write\" (list (cons 'path \"$TOOL_FILE\") (cons 'text \"alpha beta\")))" | grep '(tool . "write")'
grep '^alpha beta$' "$TOOL_FILE"
"$ROOT_DIR/build/psi" --eval "(psi-tool-call \"edit\" (list (cons 'path \"$TOOL_FILE\") (cons 'oldText \"beta\") (cons 'newText \"gamma\")))" | grep '(tool . "edit")'
grep '^alpha gamma$' "$TOOL_FILE"
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "bash" (list (cons '"'"'command "printf hello")))' | grep '(output . "hello")'
"$ROOT_DIR/build/psi" --eval "(psi-tool-call \"grep\" (list (cons 'pattern \"alpha gamma\") (cons 'path \"$TOOL_FILE\") (cons 'literal #t)))" | grep '(tool . "grep")'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "find" (list (cons '"'"'pattern "*.md") (cons '"'"'path ".") (cons '"'"'limit 5)))' | grep '(tool . "find")'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "ls" (list (cons '"'"'path ".") (cons '"'"'limit 5)))' | grep '(tool . "ls")'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "scheme" (list (cons '"'"'mode "summary")))' | grep 'psi Scheme runtime'
"$ROOT_DIR/build/psi" --eval '(psi-tool-call "scheme" (list (cons '"'"'mode "eval") (cons '"'"'expression "(length (psi-tool-specs))")))' | grep '(result . "8")'
"$ROOT_DIR/build/psi" --eval "(begin (psi-handle-event 'tool-call (list (cons 'id \"w1\") (cons 'tool \"write\") (cons 'input (list (cons 'path \"$TOOL_FILE\") (cons 'content \"delta\"))))) (let ((result (psi-tool-call \"write\" (list (cons 'path \"$TOOL_FILE\") (cons 'content \"delta\"))))) (psi-handle-event 'tool-result (list (cons 'id \"w1\") (cons 'tool \"write\") (cons 'result result)))))" | grep 'updated'
"$ROOT_DIR/build/psi" --eval "(begin (psi-handle-event 'tool-call (list (cons 'id \"w1\") (cons 'tool \"write\") (cons 'input (list (cons 'path \"$TOOL_FILE\") (cons 'content \"delta\"))))) (let ((result (psi-tool-call \"write\" (list (cons 'path \"$TOOL_FILE\") (cons 'content \"delta\"))))) (psi-handle-event 'tool-result (list (cons 'id \"w1\") (cons 'tool \"write\") (cons 'result result)))))" | grep 'delta'
"$ROOT_DIR/build/psi" --system-prompt | grep '^Available tools:$'
"$ROOT_DIR/build/psi" --system-prompt | grep 'scheme: Inspect or evaluate the embedded Scheme runtime'
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
    "$ROOT_DIR/build/psi" --session "$AGENT_SESSION" --agent 'Reply with exactly: second turn ok' --model "${PSI_ANTHROPIC_MODEL:-claude-opus-4-7}" --max-tokens 64 | grep 'second turn ok'
    grep '"role":"tool-call"' "$AGENT_SESSION"
    grep '"role":"tool-result"' "$AGENT_SESSION"
    "$ROOT_DIR/build/psi" --session "$AGENT_SESSION" --compact 4 --model "${PSI_ANTHROPIC_MODEL:-claude-opus-4-7}" --max-tokens 256 | grep .
    grep '"role":"compaction-summary"' "$AGENT_SESSION"
fi
