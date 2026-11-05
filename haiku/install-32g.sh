#!/usr/bin/env bash
# Top-level host-side driver for the Full (32 GB) install flow.
# Prints the exact sequence per phase. GUI steps (DriveSetup,
# Installer) need VNC; the dispatcher script at /PSIGUEST/go
# handles the rest with one short command typed on each phase.
#
# Usage:  bash install-32g.sh

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

cat <<EOF
Haiku r1beta5 — real Installer, 32 GB BFS target.  Phases:

Phase 0 — host assets
  cd "$DIR"
  ./fetch-iso.sh
  ./build-guest-cd.sh
  rm -f disk.qcow2
  qemu-img create -f qcow2 disk.qcow2 32G

Phase 1 — TCG Installer (slow, ~6 min)
  HAIKU_ACCEL=tcg HAIKU_ATTACH_ISO=1 HAIKU_BOOT_ORDER=d \\
    bash "$DIR/run-vm-persist.sh"
  # In the VNC viewer (localhost:5900):
  #   1. Welcome → Install Haiku
  #   2. Installer: Continue → "No partitions" OK → Set up partitions
  #   3. DriveSetup: select QEMU HARDDISK (32 GiB), Disk > Initialize
  #      > Intel Partition Map, Continue, Write changes, OK
  #   4. select Empty space, Partition > Create, Create, Write
  #   5. select new partition, Partition > Format > Be File System,
  #      Continue, Format, Write, OK
  #   6. close DriveSetup
  #   7. Installer: Onto → open dropdown → Enter (picks 32 GiB; click
  #      is flaky under TCG), Begin.
  #   8. wait for "Installation completed", click the yellow close
  #      on the Installer window (NOT Restart — that tries to boot
  #      from the unfixed-MBR disk).

Phase 2 — MBR fix inside Live CD.
  # VM is still at Live-CD desktop. Open Terminal, type (14 chars):
  sh /PSIGUEST/go
  # The 'go' dispatcher detects "Live CD + installed disk" and runs
  # fix-boot.sh (writembr + makebootable + clean shutdown). QEMU
  # will exit when done.

Phase 3 — disk-only KVM boot + psi install
  bash "$DIR/run-vm-persist.sh"  # defaults: kvm, ide, boot=c, PSIGUEST CD only
  # On desktop: Terminal → sh /PSIGUEST/go  →  prints ssh command.
  # Then from the host:
  ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes -p 2222 user@localhost \\
      "ANTHROPIC_API_KEY='\$ANTHROPIC_API_KEY' sh /PSIGUEST/go build"
  # install-psi.sh stops after deps + staged haiku update, asks for reboot.
  ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes -p 2222 user@localhost \\
      "nohup /boot/system/bin/shutdown -r -q >/dev/null &"
  # Wait ~45s, then:
  ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes -p 2222 user@localhost \\
      "sh /PSIGUEST/go build"   # phase 2 of install-psi: compile + install

Sanity check:
  ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes -p 2222 user@localhost \\
      "source /boot/home/config/settings/profile && \\
       psi --agent='reply one word: OK' --max-tokens=10"

Typing budget, VNC side:  two 14-character commands total
  Phase 2:  sh /PSIGUEST/go
  Phase 3:  sh /PSIGUEST/go
Everything else runs via clicks or ssh.
EOF
