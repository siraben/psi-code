#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$ROOT_DIR/build/psi" --eval '(+ 1 2 3)' | grep '^6$'
"$ROOT_DIR/build/psi" --print 'hello' | grep 'prompt: hello'
