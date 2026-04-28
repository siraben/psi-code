#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: search.sh [--count N] [--json] <query>

Environment:
  BRAVE_SEARCH_API_KEY or PSI_BRAVE_SEARCH_API_KEY
EOF
}

count=5
emit_json=0
query_parts=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --count)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      count="$2"
      shift 2
      ;;
    --json)
      emit_json=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      query_parts+=("$1")
      shift
      ;;
  esac
done

if [ "${#query_parts[@]}" -eq 0 ]; then
  usage
  exit 2
fi

api_key="${BRAVE_SEARCH_API_KEY:-${PSI_BRAVE_SEARCH_API_KEY:-}}"
if [ -z "${api_key}" ]; then
  echo "missing BRAVE_SEARCH_API_KEY or PSI_BRAVE_SEARCH_API_KEY" >&2
  exit 2
fi

query="${query_parts[*]}"
response="$(
  curl -fsS --get \
    -H "Accept: application/json" \
    -H "X-Subscription-Token: ${api_key}" \
    --data-urlencode "q=${query}" \
    --data-urlencode "count=${count}" \
    --data-urlencode "search_lang=en" \
    "https://api.search.brave.com/res/v1/web/search"
)"

if [ "${emit_json}" -eq 1 ]; then
  printf '%s\n' "${response}"
  exit 0
fi

BRAVE_SEARCH_RESPONSE="${response}" python3 - "${query}" <<'PY'
import json
import os
import sys

query = sys.argv[1]
payload = os.environ.get("BRAVE_SEARCH_RESPONSE", "")
data = json.loads(payload)
results = ((data.get("web") or {}).get("results") or [])

print(f"Query: {query}")
if not results:
    print("No results.")
    raise SystemExit(0)

for index, item in enumerate(results, 1):
    title = (item.get("title") or "").strip()
    url = (item.get("url") or "").strip()
    snippet = (item.get("description") or "").strip().replace("\n", " ")
    print(f"{index}. {title}")
    if url:
        print(f"   URL: {url}")
    if snippet:
        print(f"   Snippet: {snippet}")
PY
