#!/usr/bin/env bash
# Push the current repo state + helper scripts to a running Haiku VM
# and rebuild psi there. Use after editing psi source on the host:
#
#     bash haiku/sync-psi.sh
#
# Assumes the VM is up on localhost:2222 with our ssh pubkey authorised
# (UserBootscript auto-starts sshd on boot). If you haven't SSH'd in
# yet on this VM, run `sh /PSIGUEST/go` in the VNC terminal first.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HAIKU="$REPO/haiku"
KEY="${HAIKU_SSH_KEY:-$HOME/.ssh/psi_haiku}"
PORT="${HAIKU_SSH_PORT:-2222}"
USER_HOST="${HAIKU_SSH_HOST:-user@localhost}"

# Source env if present so we can re-persist the key on the guest.
if [ -f "$REPO/.env.local" ]; then
  # shellcheck disable=SC1091
  set -a; . "$REPO/.env.local"; set +a
fi

say() { printf '\n=== %s ===\n' "$*"; }

say "pack psi source"
TGZ=$(mktemp --suffix=.tgz)
trap 'rm -f "$TGZ"' EXIT
( cd "$REPO" && tar --transform='s,^\./,,' \
    --exclude=./haiku --exclude=./pi-mono --exclude=./build --exclude=./result \
    --exclude='./result-*' --exclude=./sessions --exclude=./i686-transcripts \
    --exclude=./.env.local --exclude=./.git --exclude=./apr221504.jsonl \
    --exclude=__pycache__ --exclude=./.claude \
    -czf "$TGZ" . )
du -h "$TGZ" | awk '{print $1}'

say "ensure argtable3 is cached"
bash "$HAIKU/fetch-argtable3.sh"

say "scp to VM /tmp/"
scp -q -i "$KEY" -o IdentitiesOnly=yes -P "$PORT" \
    "$TGZ" \
    "$HAIKU/guest/install-psi.sh" \
    "$HAIKU/guest/go" \
    "$HAIKU/guest/ssh-bootstrap.sh" \
    "$HAIKU/guest/fix-boot.sh" \
    "$HAIKU/downloads/argtable3/argtable3.c" \
    "$HAIKU/downloads/argtable3/argtable3.h" \
    "$USER_HOST:/tmp/"
ssh -q -i "$KEY" -o IdentitiesOnly=yes -p "$PORT" "$USER_HOST" "
  mv /tmp/$(basename "$TGZ") /tmp/psi-src.tgz
  for h in install-psi.sh go ssh-bootstrap.sh fix-boot.sh; do
    cp /tmp/\$h /boot/home/bin/\$h && chmod +x /boot/home/bin/\$h
  done
"

say "rebuild psi on VM"
ssh -i "$KEY" -o IdentitiesOnly=yes -p "$PORT" "$USER_HOST" \
    "ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:-}' PATH=/boot/home/bin:\$PATH go build 2>&1 | tail -12"

say "smoke-test"
ssh -i "$KEY" -o IdentitiesOnly=yes -p "$PORT" "$USER_HOST" \
    "source /boot/home/config/settings/profile && psi --version"
