#!/usr/bin/env bash
# Run a shell command inside the running guest via the serial control channel.
#   ./guest-run.sh 'psi --version'
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOCK="$HERE/console.sock"
WAIT="${WAIT:-8}"

[ -S "$SOCK" ] || { echo "guest not running (no $SOCK)" >&2; exit 1; }

{ printf '%s\n' "$*"; command sleep "$WAIT"; } \
	| timeout $((WAIT + 15)) socat - UNIX-CONNECT:"$SOCK"
