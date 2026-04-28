#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: fetch.sh <url>

Environment:
  PSI_WEB_FETCH_MAX_BYTES   default: 40000
  PSI_WEB_FETCH_TIMEOUT     default: 20
EOF
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

url="$1"
max_bytes="${PSI_WEB_FETCH_MAX_BYTES:-40000}"
timeout="${PSI_WEB_FETCH_TIMEOUT:-20}"

curl -fsSL \
  --max-time "${timeout}" \
  -H 'User-Agent: psi-web-search-skill/1.0' \
  "${url}" \
| python3 -c 'import sys; limit = int(sys.argv[1]); sys.stdout.buffer.write(sys.stdin.buffer.read(limit))' "${max_bytes}"
