#!/usr/bin/env bash
# Boot Haiku live CD with the guest CD attached, no persistent disk.
# This is the stable workflow because the installed-disk boot path is
# blocked by a Haiku R1/beta5 bug on our config; live-CD + guest CD
# gets us to a desktop where we can build psi natively.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$DIR/downloads/haiku-r1beta5-x86_64-anyboot.iso"
GUEST="$DIR/guest.iso"

[ -f "$ISO" ]   || { echo "missing $ISO";   exit 1; }
[ -f "$GUEST" ] || { echo "missing $GUEST"; exit 1; }

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
  gtk)  DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl)  DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc)  DISPLAY_ARGS=(-display vnc=:0); echo "VNC on localhost:5900" ;;
  none) DISPLAY_ARGS=(-nographic) ;;
esac

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp 4 -m 4096 \
  -drive media=cdrom,file="$ISO",readonly=on \
  -drive media=cdrom,file="$GUEST",readonly=on \
  -boot order=d,menu=on \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222 \
  -device e1000,netdev=n0 \
  -vga std \
  -device intel-hda -device hda-duplex \
  -usb -device usb-tablet \
  -name "psi on Haiku (live)" \
  "${DISPLAY_ARGS[@]}"
