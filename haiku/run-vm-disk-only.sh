#!/usr/bin/env bash
# Boot Haiku from the installed qcow2 only — CDs intentionally
# detached so Haiku's bootloader does not get confused by the live-CD
# Haiku volume.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/disk.qcow2"

if [ ! -f "$DISK" ]; then
  echo "missing $DISK"
  exit 1
fi

KVM_FLAG=()
ACCEL="${HAIKU_ACCEL:-kvm}"
if [ "$ACCEL" = "kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  KVM_FLAG=(-enable-kvm -cpu host)
else
  ACCEL="tcg"
fi

MODE="${HAIKU_DISPLAY:-}"
if [ -z "$MODE" ]; then
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then MODE=gtk; else MODE=vnc; fi
fi
DISPLAY_ARGS=()
case "$MODE" in
  gtk) DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl) DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc) DISPLAY_ARGS=(-display vnc=:0); echo "VNC on localhost:5900" ;;
  none) DISPLAY_ARGS=(-nographic) ;;
esac

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp 4 -m 8192 \
  -drive if=virtio,file="$DISK",format=qcow2 \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222 \
  -device e1000,netdev=n0 \
  -vga std \
  -device intel-hda -device hda-duplex \
  -usb -device usb-tablet \
  -name "psi on Haiku (disk only)" \
  "${DISPLAY_ARGS[@]}"
