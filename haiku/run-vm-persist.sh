#!/usr/bin/env bash
# Boot Haiku from the persistent qcow2.  Supports both the fast CoW-on-
# anyboot variant and the full 32 GB Installer variant, selected by env:
#
#   HAIKU_ACCEL       kvm (default) | tcg         — tcg only needed
#                     during the real Installer (KVM dies mid-install
#                     with "General system error", see JOURNEY.md §11).
#   HAIKU_DISK_IF     ide (default) | virtio      — ide is safest for
#                     Haiku's stage-1 loader + SeaBIOS.
#   HAIKU_BOOT_ORDER  c (default; disk)           — set to 'd' to boot
#                     from CD first (needed while running the Installer
#                     and while fixing the MBR from Live CD).
#   HAIKU_ATTACH_ISO  unset (default) | any value — when set, attaches
#                     the anyboot ISO alongside the disk.  Required for
#                     Phase 1 (Install) and Phase 2 (Live-CD MBR fix).
#                     The PSIGUEST CD is ALWAYS attached (it's tiny
#                     and used by the single-command `go` dispatcher).
#   HAIKU_ATTACH_CDS  deprecated alias for HAIKU_ATTACH_ISO.
#   HAIKU_DISPLAY     vnc (default, :0) | gtk | sdl | none
#   HAIKU_RES         "1920x1080" default; WxH that QEMU's stdvga will
#                     offer to the guest. Combine with a matching
#                     mode line in /boot/home/config/settings/kernel/
#                     drivers/vesa on the guest (fix-boot.sh /
#                     install-psi.sh seed this).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/disk.qcow2"
GUEST="$DIR/guest.iso"
ISO="$DIR/downloads/haiku-r1beta5-x86_64-anyboot.iso"

[ -f "$DISK" ]  || { echo "missing $DISK"; exit 1; }
[ -f "$GUEST" ] || { echo "missing $GUEST"; exit 1; }
[ -f "$ISO" ]   || { echo "missing $ISO"; exit 1; }

KVM_FLAG=()
ACCEL="${HAIKU_ACCEL:-kvm}"
if [ "$ACCEL" = "kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  KVM_FLAG=(-enable-kvm -cpu host)
else
  ACCEL="tcg"
fi

MODE="${HAIKU_DISPLAY:-vnc}"
DISPLAY_ARGS=()
case "$MODE" in
  gtk)  DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl)  DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc)  DISPLAY_ARGS=(-display vnc=:0); echo "VNC on localhost:5900" ;;
  none) DISPLAY_ARGS=(-nographic) ;;
esac

# Parse desired resolution (default 1920x1080).
HAIKU_RES="${HAIKU_RES:-1920x1080}"
RES_W="${HAIKU_RES%x*}"
RES_H="${HAIKU_RES#*x}"

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp 8 -m 16384 \
  -drive if=${HAIKU_DISK_IF:-ide},file="$DISK",format=qcow2 \
  -drive media=cdrom,file="$GUEST",readonly=on \
  ${HAIKU_ATTACH_ISO:+-drive media=cdrom,file="$ISO",readonly=on} \
  ${HAIKU_ATTACH_CDS:+-drive media=cdrom,file="$ISO",readonly=on} \
  -boot order="${HAIKU_BOOT_ORDER:-c}" \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222 \
  -device e1000,netdev=n0 \
  -device VGA,xres="$RES_W",yres="$RES_H",xmax="$RES_W",ymax="$RES_H" \
  -device intel-hda -device hda-duplex \
  -usb -device usb-tablet \
  -name "psi on Haiku (persist)" \
  "${DISPLAY_ARGS[@]}"
