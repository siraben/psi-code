#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
SESSION_FILE="$TMP_DIR/session.jsonl"

trap 'rm -rf "$TMP_DIR"' EXIT

"$ROOT_DIR/build/psi" --eval '(+ 1 2 3)' | grep '^6$'
"$ROOT_DIR/build/psi" --eval '(if (> (string-length (psi-read-file "README.md")) 0) "ok" "bad")' | grep '^ok$'
"$ROOT_DIR/build/psi" --print 'hello' | grep 'prompt: hello'
"$ROOT_DIR/build/psi" --print 'hello' | grep 'session-messages: 1'
"$ROOT_DIR/build/psi" --session "$SESSION_FILE" --print 'one' >/dev/null
"$ROOT_DIR/build/psi" --session "$SESSION_FILE" --print 'two' | grep 'session-messages: 3'
grep '"type":"session"' "$SESSION_FILE"
test "$(grep -c '"type":"message"' "$SESSION_FILE")" -eq 4
grep '"text":"two"' "$SESSION_FILE"
