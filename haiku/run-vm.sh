#!/usr/bin/env bash
# Launch Haiku in QEMU with the anyboot ISO and the guest CD attached.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$DIR/downloads/haiku-r1beta5-x86_64-anyboot.iso"
GUEST="$DIR/guest.iso"
DISK="$DIR/disk.qcow2"

if [ ! -f "$ISO" ]; then
  echo "Missing $ISO — run ./fetch-iso.sh first."
  exit 1
fi
if [ ! -f "$GUEST" ]; then
  echo "Missing $GUEST — run ./build-guest-cd.sh first."
  exit 1
fi

if [ ! -f "$DISK" ]; then
  echo "Creating persistent disk $DISK (16G sparse)."
  qemu-img create -f qcow2 "$DISK" 16G
fi

# KVM if available, else plain TCG.
ACCEL="tcg"
KVM_FLAG=()
# Opt-in KVM with HAIKU_ACCEL=kvm. Default is TCG because Haiku's
# installer has tripped a "General system error" at the llvm12_libs
# package reliably under KVM on this host; TCG dodges it.
if [ "${HAIKU_ACCEL:-tcg}" = "kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL="kvm"
  KVM_FLAG=(-enable-kvm -cpu host)
fi

# Display: prefer GTK when a graphical session is present, otherwise
# VNC so a remote/headless invocation still works. Override with
# HAIKU_DISPLAY=gtk|sdl|vnc|none.
MODE="${HAIKU_DISPLAY:-}"
if [ -z "$MODE" ]; then
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    MODE=gtk
  else
    MODE=vnc
  fi
fi

DISPLAY_ARGS=()
case "$MODE" in
  gtk) DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl) DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc) DISPLAY_ARGS=(-display vnc=:0)
       echo "QEMU VNC: connect a VNC client to localhost:5900" ;;
  none) DISPLAY_ARGS=(-nographic) ;;
  *) echo "Unknown HAIKU_DISPLAY=$MODE"; exit 1 ;;
esac

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp 4 \
  -m 8192 \
  -drive if=virtio,file="$DISK",format=qcow2 \
  -drive media=cdrom,file="$ISO",readonly=on \
  -drive media=cdrom,file="$GUEST",readonly=on \
  -boot order=dc,menu=on \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222 \
  -device e1000,netdev=n0 \
  -vga std \
  -device intel-hda -device hda-duplex \
  -usb -device usb-tablet \
  -name "psi on Haiku" \
  "${DISPLAY_ARGS[@]}"
