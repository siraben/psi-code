#!/bin/bash
# Bring up sshd inside Haiku so the host can drive the rest of the
# build over SSH. Safe to re-run.

say() { printf '\n=== %s ===\n' "$*"; }

USER_NAME="$(whoami)"
PASS="${PSI_SSH_PASSWORD:-hello}"

say "Running as user: $USER_NAME (will set password to: $PASS)"

say "1/4  ensure openssh is installed"
if ! command -v sshd >/dev/null 2>&1; then
  pkgman install -y openssh || { echo "openssh install failed"; exit 1; }
fi
command -v sshd >/dev/null || { echo "sshd still missing"; exit 1; }

say "2/4  set password for $USER_NAME"
# Haiku's passwd accepts stdin with the password entered twice.
printf '%s\n%s\n' "$PASS" "$PASS" | passwd "$USER_NAME" \
  || echo "passwd returned non-zero — continuing, may already be set"

say "3/4  generate host keys if missing"
SSHDIR=/boot/system/settings/ssh
mkdir -p "$SSHDIR"
ssh-keygen -A 2>&1 | tail -5 || true

say "4/4  (re)start sshd on port 22"
# Kill any prior sshd so we're not double-binding.
for pid in $(pgrep -x sshd 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 1
sshd
sleep 1

if pgrep -x sshd >/dev/null; then
  echo
  echo "----------------------------------------------"
  echo "sshd is running."
  echo "From the host:  ssh -p 2222 $USER_NAME@localhost"
  echo "Password:       $PASS"
  echo "----------------------------------------------"
else
  echo "sshd failed to start — running with debug:"
  sshd -d -e
fi
