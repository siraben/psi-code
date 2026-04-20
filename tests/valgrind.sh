#!/usr/bin/env bash
# Run psi against a non-agent exercise set under valgrind memcheck.
#
# Definite + indirect leaks are treated as failures. We deliberately
# don't chase "still reachable" allocations (Lua/cJSON/libcurl keep
# pools alive for process lifetime). Invalid reads/writes and jumps on
# uninitialized values are hard failures via --error-exitcode.
#
# Overrides:
#   PSI       path to psi binary (default: build/psi or psi on PATH)
#   VALGRIND  path to valgrind (default: valgrind on PATH)

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

PSI="${PSI:-}"
if [ -z "$PSI" ]; then
  if [ -x "$ROOT_DIR/build/psi" ]; then
    PSI="$ROOT_DIR/build/psi"
  elif command -v psi >/dev/null 2>&1; then
    PSI=psi
  else
    echo "psi binary not found; build it or set PSI=<path>" >&2
    exit 1
  fi
fi

VALGRIND="${VALGRIND:-valgrind}"
if ! command -v "$VALGRIND" >/dev/null 2>&1; then
  echo "valgrind not on PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VG_OPTS=(
  --tool=memcheck
  --error-exitcode=42
  --leak-check=full
  --errors-for-leak-kinds=definite,indirect
  --show-leak-kinds=definite,indirect
  --track-origins=yes
  --child-silent-after-fork=yes
  --num-callers=30
)

run() {
  echo ">>> valgrind $*"
  "$VALGRIND" "${VG_OPTS[@]}" "$PSI" "$@" >/dev/null
}

run --version
run --help
run --eval 'return 1 + 2 + 3'
run --eval 'return psi.json_decode("{\"a\":1}").a'
run --eval 'return require("psi.tools").all()[1].name'
run --eval 'local r = require("psi.tools").dispatch("read", {path="README.md"}); return tostring(r.ok)'
run --eval 'local r = require("psi.tools").dispatch("bash", {command="printf hi"}); return r.extras.output'
run --system-prompt
run --print 'hello'

# Session round-trip: write then re-load the same JSONL.
SESSION="$TMP_DIR/session.jsonl"
run --session "$SESSION" --print 'one'
run --session "$SESSION" --print 'two'

echo "valgrind: no memory errors"
