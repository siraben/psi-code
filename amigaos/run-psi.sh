#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge_dir="${PSI_AMIGA_BRIDGE_DIR:-"$root/.amiga-bridge"}"
psi_out="${PSI_AMIGA_PSI_OUT:-"$root/amigaos/result-psi"}"
tools_out="${PSI_AMIGA_TOOLS_OUT:-"$root/amigaos/result-tools"}"

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$root/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$root/.env.local"
  set +a
fi

NIXPKGS_ALLOW_UNFREE=1 nix build --impure \
  "$root/amigaos#psi-amigaos" "$root/amigaos#amitools" \
  --out-link "$psi_out" >/dev/null
# Multiple installables with one --out-link produce result-psi, result-psi-1.
if [ -x "$psi_out-1/bin/vamos" ]; then
  rm -f "$tools_out"
  ln -s "$(readlink -f "$psi_out-1")" "$tools_out"
fi

mkdir -p "$bridge_dir"
rm -f "$bridge_dir"/req-* 2>/dev/null || true
pkill -f "psi-amiga-http-bridge $bridge_dir" 2>/dev/null || true

env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  "$psi_out/bin/psi-amiga-http-bridge" "$bridge_dir" \
  >"$bridge_dir/bridge.log" 2>&1 &
bridge_pid=$!
trap 'kill "$bridge_pid" 2>/dev/null || true' EXIT

out_file="$(mktemp)"
err_file="$(mktemp)"
cleanup_files() {
  rm -f "$out_file" "$err_file"
  kill "$bridge_pid" 2>/dev/null || true
}
trap cleanup_files EXIT

set +e
"$tools_out/bin/vamos" -V "bridge:$bridge_dir" -- "$psi_out/bin/psi" "$@" >"$out_file" 2>"$err_file"
status=$?
set -e

cat "$out_file"

bridge_status=""
for f in "$bridge_dir"/*.status; do
  [ -f "$f" ] || continue
  bridge_status="$(cat "$f" 2>/dev/null || true)"
done

if [ "$status" -ne 0 ] &&
   [ "$bridge_status" = "200" ] &&
   grep -q '[^[:space:]]' "$out_file" &&
   ! grep -q "failed" "$out_file"; then
  # amitools/vamos can raise Python-side cleanup errors after the m68k
  # process has already completed successfully. Hide that false failure
  # for the bridge-backed agent path.
  exit 0
fi

cat "$err_file" >&2
if [ -s "$bridge_dir/bridge.log" ]; then
  cat "$bridge_dir/bridge.log" >&2
fi
exit "$status"
