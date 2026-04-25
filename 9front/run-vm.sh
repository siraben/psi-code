#!/usr/bin/env bash
# Boot a 9front VM in QEMU.
#
# Env knobs:
#   VM_ACCEL       kvm (default) | tcg
#   VM_DISPLAY     vnc (default, :0) | gtk | sdl | none
#   VM_RES         1920x1080 (default) — VNC framebuffer size
#   VM_ATTACH_ISO  unset (default) | any value — attach install ISO
#                  as secondary CD; set during initial install
#   VM_BOOT_ORDER  c (default, disk) | d (CD first, for install)
#   VM_MEM         2048 (default MB)
#   VM_SMP         4 (default vCPUs)
#
# 9front notes (per exploration):
#   - KVM works (unlike Haiku's Installer); use -cpu host.
#   - Prefer virtio-scsi over virtio-blk (driver is more mature).
#   - USB mouse (scroll wheel) instead of PS/2.
#   - Port forwards: 2222 (exportfs via aux/listen1), 17019/17020
#     (ndb / 9P if we wire them up later).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/disk.qcow2"
ISO="$DIR/downloads/9front-11554.amd64.iso"

[ -f "$DISK" ] || { echo "missing $DISK  —  run:  qemu-img create -f qcow2 disk.qcow2 32G"; exit 1; }

if [ -n "${VM_ATTACH_ISO:-}" ]; then
  [ -f "$ISO" ] || { echo "missing $ISO — run ./fetch-iso.sh first"; exit 1; }
fi

ACCEL="${VM_ACCEL:-kvm}"
KVM_FLAG=()
if [ "$ACCEL" = "kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  KVM_FLAG=(-enable-kvm -cpu host)
else
  ACCEL="tcg"
fi

MODE="${VM_DISPLAY:-vnc}"
DISPLAY_ARGS=()
case "$MODE" in
  gtk)  DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl)  DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc)  DISPLAY_ARGS=(-display vnc=:0); echo "VNC on localhost:5900" ;;
  none) DISPLAY_ARGS=(-nographic) ;;
esac

RES="${VM_RES:-1920x1080}"
RES_W="${RES%x*}"
RES_H="${RES#*x}"

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp "${VM_SMP:-4}" -m "${VM_MEM:-2048}" \
  -device virtio-scsi-pci,id=scsi \
  -drive if=none,id=vd0,file="$DISK",format=qcow2 -device scsi-hd,drive=vd0 \
  ${VM_ATTACH_ISO:+-drive if=none,id=vd1,file="$ISO",format=raw,readonly=on -device scsi-cd,drive=vd1,bootindex=0} \
  -boot order="${VM_BOOT_ORDER:-c}" \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222,hostfwd=tcp::17019-:17019 \
  -device virtio-net-pci,netdev=n0 \
  -device VGA,xres="$RES_W",yres="$RES_H",xmax="$RES_W",ymax="$RES_H" \
  -device intel-hda -device hda-duplex \
  -usb -device usb-mouse \
  -name "psi on 9front" \
  "${DISPLAY_ARGS[@]}"
