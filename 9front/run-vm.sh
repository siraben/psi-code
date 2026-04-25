#!/usr/bin/env bash
# Boot the 9front VM. Either fresh, or resumed from a saved snapshot
# so all our auth + listeners come up running.
#
# Env knobs:
#   VM_ACCEL       kvm (default) | tcg
#   VM_DISPLAY     vnc (default, :0) | gtk | sdl | none
#   VM_RES         1280x1024 (default) — VGA framebuffer size
#   VM_ATTACH_ISO  unset (default) | any value — attach install ISO
#                  as secondary CD; set during initial install
#   VM_BOOT_ORDER  c (default, disk) | d (CD first, for install)
#   VM_MEM         2048 (default MB)
#   VM_SMP         4 (default vCPUs)
#   VM_LOADVM      snapshot tag to resume from (default: bootstrapped
#                  if such a snapshot exists, else fresh boot)
#
# Snapshot workflow:
#   1. First boot: leave VM_LOADVM unset, do the one-time bootstrap
#      (`rc /tmp/up.rc` + walk through auth prompts), then via QEMU
#      monitor: `savevm bootstrapped`. Every subsequent
#      `bash run-vm.sh` resumes that snapshot — no keystrokes, no
#      bootstrap, drawterm-cmd / drawterm-shell work in milliseconds.
#   2. Force a cold boot: `VM_LOADVM=- bash run-vm.sh`.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/disk.qcow2"
ISO="$DIR/downloads/9front-11554.amd64.iso"

[ -f "$DISK" ] || { echo "missing $DISK  —  run:  qemu-img create -f qcow2 disk.qcow2 32G"; exit 1; }
[ -z "${VM_ATTACH_ISO:-}" ] || [ -f "$ISO" ] || { echo "missing $ISO — run ./fetch-iso.sh first"; exit 1; }

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

# Resolve loadvm. `-` means "force cold boot". Empty means "use
# bootstrapped if it exists".
LOADVM_ARGS=()
LOADVM="${VM_LOADVM-}"
if [ "$LOADVM" = "-" ]; then
  :  # explicit cold boot
elif [ -n "$LOADVM" ]; then
  LOADVM_ARGS=(-loadvm "$LOADVM")
elif qemu-img snapshot -l "$DISK" 2>/dev/null | awk '{print $2}' | grep -qx bootstrapped; then
  LOADVM_ARGS=(-loadvm bootstrapped)
  echo "resuming snapshot 'bootstrapped'"
fi

exec qemu-system-x86_64 \
  "${KVM_FLAG[@]}" \
  -machine q35,accel="$ACCEL" \
  -smp "${VM_SMP:-4}" -m "${VM_MEM:-2048}" \
  -device virtio-scsi-pci,id=scsi \
  -drive if=none,id=vd0,file="$DISK",format=qcow2 -device scsi-hd,drive=vd0 \
  ${VM_ATTACH_ISO:+-drive if=none,id=vd1,file="$ISO",format=raw,readonly=on -device scsi-cd,drive=vd1,bootindex=0} \
  -boot order="${VM_BOOT_ORDER:-c}" \
  -netdev user,id=n0,hostfwd=tcp::2222-:2222,hostfwd=tcp::17019-:17019,hostfwd=tcp::17020-:17020 \
  -device virtio-net-pci,netdev=n0 \
  -vga std \
  -monitor unix:/tmp/9qmon,server,nowait \
  -usb -device usb-tablet \
  -name "psi on 9front" \
  "${DISPLAY_ARGS[@]}" \
  "${LOADVM_ARGS[@]}"
