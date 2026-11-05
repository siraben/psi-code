#!/bin/bash
# Run this in a Live-CD Terminal after the Installer completes, *before*
# rebooting into the freshly installed disk. The Installer writes the
# BFS stage-1 but often leaves the MBR unbootable — SeaBIOS stops with
# "bios_ia32 stage1: Failed to load OS". This script:
#   1. mounts the newly-installed partition (via raw device, avoiding
#      the Live CD's same-named "Haiku" volume);
#   2. writes the Haiku MBR bootcode (`writembr`);
#   3. (re)writes the BFS stage-1 via `makebootable` targeting the
#      actual mount point (not the raw device, which fails with
#      "Block devices not supported on this platform!");
#   4. seeds /boot/home/bin/go + /boot/home/bin/psi-helpers on the
#      disk, so after reboot the user can just type `go` (2 chars)
#      instead of `sh /PSIGUEST/go`;
#   5. seeds a UserBootscript on the disk that auto-mounts PSIGUEST
#      (needed because Tracker doesn't auto-mount CDs on disk-boot)
#      and auto-starts sshd;
#   6. syncs and shuts down cleanly so BFS journal commits.
#
# Safe to run once on a clean post-install Live-CD session.

set -e

RAW="${HAIKU_DISK_RAW:-/dev/disk/scsi/0/0/0/raw}"
PART="${HAIKU_DISK_PART:-/dev/disk/scsi/0/0/0/0}"
MNT=/tmp/fixboot-mnt
CD=/PSIGUEST

say() { printf '\n=== %s ===\n' "$*"; }

# Ensure the PSIGUEST CD is mounted (it normally is on Live CD).
if [ ! -d "$CD" ] || [ ! -f "$CD/go" ]; then
  mountvolume PSIGUEST >/dev/null 2>&1 || true
fi

say "mount $PART"
mkdir -p "$MNT"
mount -t bfs "$PART" "$MNT"
ls "$MNT" | head

say "writembr on $RAW"
echo yes | writembr "$RAW"

say "makebootable $MNT"
makebootable "$MNT"

say "seed /boot/home/bin on the new install"
# After reboot, these live at /boot/home/bin which is on PATH once
# install-psi.sh phase 1 writes the profile. For the very first
# boot (before phase 1 runs), the user types the longer form:
#     sh /PSIGUEST/go
# PSIGUEST is auto-mounted by the new UserBootscript below.
mkdir -p "$MNT/home/bin"
for f in go ssh-bootstrap.sh fix-boot.sh install-psi.sh; do
  [ -f "$CD/$f" ] && cp "$CD/$f" "$MNT/home/bin/$f"
done
chmod +x "$MNT/home/bin/"*.sh "$MNT/home/bin/go" 2>/dev/null || true
# Short alias: running `go` (no path, no extension) should Just Work.
# /boot/home/bin is on PATH because install-psi.sh writes that to
# the profile on first run; seed a trivial profile here too so even
# before install-psi the short command works.
if [ ! -f "$MNT/home/config/settings/profile" ]; then
  mkdir -p "$MNT/home/config/settings"
  cat > "$MNT/home/config/settings/profile" <<'PROF'
# Seeded by fix-boot.sh — make `go` work from any fresh shell.
export PATH=/boot/home/bin:$PATH
PROF
fi

say "seed VESA mode (so Haiku boots at the QEMU-advertised resolution)"
mkdir -p "$MNT/home/config/settings/kernel/drivers"
# 1920x1080x32 matches run-vm-persist.sh HAIKU_RES default.
cat > "$MNT/home/config/settings/kernel/drivers/vesa" <<'VESA'
mode 1920 1080 32
VESA

say "seed UserBootscript: auto-mount PSIGUEST + auto-start sshd"
mkdir -p "$MNT/home/config/settings/boot"
cat > "$MNT/home/config/settings/boot/UserBootscript" <<'BOOT'
#!/bin/bash
LOG=/boot/home/userboot.log
exec >> "$LOG" 2>&1
echo "=== UserBootscript $(date) ==="
# Auto-mount PSIGUEST if its CD is attached — lets `/PSIGUEST/go`
# work as a fallback path.
mountvolume PSIGUEST >/dev/null 2>&1 || true
# Auto-start sshd on port 2222 with our host pubkey authorised.
if ! pgrep -x sshd >/dev/null 2>&1 && [ -x /boot/system/bin/sshd ]; then
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
  /boot/system/bin/sshd -f /tmp/sshd_config -E /tmp/sshd.log &
fi
BOOT
chmod +x "$MNT/home/config/settings/boot/UserBootscript"

# Also pre-seed the ssh host key + authorized_keys so sshd can start
# on the very first disk boot without any extra bootstrap step.
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILeNLzDKmfou3OsciKEoGSIzBaL71UnnL/BliwVkDYdD psi-haiku'
mkdir -p "$MNT/home/.ssh" "$MNT/home/config/settings/ssh"
echo "$PUBKEY" > "$MNT/home/.ssh/authorized_keys"
echo "$PUBKEY" > "$MNT/home/config/settings/ssh/authorized_keys"
chmod 700 "$MNT/home/.ssh" "$MNT/home/config/settings/ssh"
chmod 600 "$MNT/home/.ssh/authorized_keys" "$MNT/home/config/settings/ssh/authorized_keys"
if [ ! -f "$MNT/home/config/settings/ssh/hk_ed25519" ]; then
  # Generate into a host-side tmp then copy across — ssh-keygen on
  # Haiku writes OK but wants the output path writable.
  T=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -f "$T/hk" >/dev/null 2>&1
  cp "$T/hk"     "$MNT/home/config/settings/ssh/hk_ed25519"
  cp "$T/hk.pub" "$MNT/home/config/settings/ssh/hk_ed25519.pub"
  rm -rf "$T"
fi

say "sync"
sync

say "shutdown"
# -q = no confirm. This clean-unmounts BFS; journal commits; qemu
# exits. Never kill the VM here — that corrupts the install.
/boot/system/bin/shutdown -q
