#!/bin/bash
# Bring up sshd on port 2222 in Haiku (disk-backed), with our host key
# authorised. Safe to re-run. Prints PORT_READY when listening.
set +e

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILeNLzDKmfou3OsciKEoGSIzBaL71UnnL/BliwVkDYdD psi-haiku'

say() { printf '\n=== %s ===\n' "$*"; }

say "install openssh"
pkgman install -y openssh 2>&1 | tail -5

# Even when pkgman says "reboot needed", the hpkg lands in packages/.
# Extract it into /tmp/ext so binaries are immediately usable without
# a reboot (that's what worked in the prior journey).
if ! command -v sshd >/dev/null 2>&1; then
  say "extract openssh hpkg"
  mkdir -p /tmp/ext
  for p in /boot/system/packages/openssh-*.hpkg; do
    [ -f "$p" ] && package extract -C /tmp/ext "$p"
  done
  export PATH=/tmp/ext/bin:$PATH
fi

command -v sshd >/dev/null 2>&1 || { echo "sshd still missing"; exit 1; }

say "install authorized_keys"
mkdir -p /boot/home/.ssh /boot/home/config/settings/ssh
chmod 700 /boot/home/.ssh /boot/home/config/settings/ssh 2>/dev/null
grep -qF "$PUBKEY" /boot/home/.ssh/authorized_keys 2>/dev/null || \
  printf '%s\n' "$PUBKEY" >> /boot/home/.ssh/authorized_keys
grep -qF "$PUBKEY" /boot/home/config/settings/ssh/authorized_keys 2>/dev/null || \
  printf '%s\n' "$PUBKEY" >> /boot/home/config/settings/ssh/authorized_keys
chmod 600 /boot/home/.ssh/authorized_keys /boot/home/config/settings/ssh/authorized_keys 2>/dev/null

say "generate host key"
if [ ! -f /boot/home/config/settings/ssh/hk_ed25519 ]; then
  ssh-keygen -t ed25519 -N '' -f /boot/home/config/settings/ssh/hk_ed25519 2>&1 | tail -5
fi

say "kill prior sshd"
for pid in $(ps | awk '/sshd/ && !/awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
sleep 1

say "write sshd_config"
cat > /tmp/sshd_config <<CFG
Port 2222
HostKey /boot/home/config/settings/ssh/hk_ed25519
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
AuthorizedKeysFile /boot/home/config/settings/ssh/authorized_keys /boot/home/.ssh/authorized_keys
PidFile /tmp/sshd.pid
Subsystem sftp internal-sftp
LogLevel INFO
CFG

say "start sshd"
SSHD_BIN="$(command -v sshd 2>/dev/null)"
[ -z "$SSHD_BIN" ] && SSHD_BIN=/boot/system/bin/sshd
"$SSHD_BIN" -f /tmp/sshd_config -E /tmp/sshd.log
sleep 2
if ss -tln 2>/dev/null | grep -q :2222 || netstat -ln 2>/dev/null | grep -q :2222; then
  echo PORT_READY
else
  ps | grep sshd
  echo "sshd log:"; cat /tmp/sshd.log 2>/dev/null | tail
fi
