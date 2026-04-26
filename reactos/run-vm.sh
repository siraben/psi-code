#!/usr/bin/env bash
# Boot ReactOS in QEMU.
#
# Modes:
#   REACTOS_MODE=live     Boot LiveCD directly (default, fastest desktop).
#   REACTOS_MODE=install  Boot BootCD installer with disk attached.
#   REACTOS_MODE=disk     Boot the installed disk.
#
# Common knobs:
#   REACTOS_DISPLAY   vnc (default) | gtk | sdl | none
#   REACTOS_VNC       :2 default, so listen on port 5902
#   REACTOS_ACCEL     kvm (default) | tcg
#   REACTOS_MEM       1024 default MB
#   REACTOS_SMP       2 default vCPUs
#   REACTOS_BRIDGE    1 default for live/disk, 0 to disable shared FAT bridge
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADS="$DIR/downloads"
VERSION="${REACTOS_VERSION:-0.4.15}"
BUILD="${REACTOS_BUILD:-release-1-gdbb43bbaeb2}"
LIVE_ISO="$DOWNLOADS/ReactOS-$VERSION-$BUILD-x86-live.iso"
BOOT_ISO="$DOWNLOADS/ReactOS-$VERSION-$BUILD-x86.iso"
DISK="$DIR/disk.qcow2"
SHARED="$DIR/shared"
BRIDGE_DIR="$SHARED/bridge"
MODE="${REACTOS_MODE:-live}"

case "$MODE" in
  live)    [ -f "$LIVE_ISO" ] || { echo "missing $LIVE_ISO; run ./reactos/fetch-isos.sh"; exit 1; } ;;
  install) [ -f "$BOOT_ISO" ] || { echo "missing $BOOT_ISO; run ./reactos/fetch-isos.sh"; exit 1; }
           [ -f "$DISK" ] || { echo "missing $DISK; run ./reactos/create-disk.sh"; exit 1; } ;;
  disk)    [ -f "$DISK" ] || { echo "missing $DISK; run ./reactos/create-disk.sh, then install first"; exit 1; } ;;
  *)       echo "unknown REACTOS_MODE=$MODE (use live, install, disk)" >&2; exit 1 ;;
esac

ACCEL="${REACTOS_ACCEL:-kvm}"
KVM_FLAG=()
if [ "$ACCEL" = "kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  KVM_FLAG=(-enable-kvm -cpu host)
else
  ACCEL="tcg"
fi

DISPLAY_MODE="${REACTOS_DISPLAY:-vnc}"
DISPLAY_ARGS=()
case "$DISPLAY_MODE" in
  gtk)  DISPLAY_ARGS=(-display gtk,show-cursor=on) ;;
  sdl)  DISPLAY_ARGS=(-display sdl,show-cursor=on) ;;
  vnc)  VNC="${REACTOS_VNC:-:2}"; DISPLAY_ARGS=(-display "vnc=$VNC"); echo "VNC on port $((5900 + ${VNC#:}))" ;;
  none) DISPLAY_ARGS=(-display none) ;;
  *)    echo "unknown REACTOS_DISPLAY=$DISPLAY_MODE" >&2; exit 1 ;;
esac

DRIVE_ARGS=()
BOOT_ORDER=c
case "$MODE" in
  live)
    DRIVE_ARGS=(-drive media=cdrom,file="$LIVE_ISO",readonly=on)
    BOOT_ORDER=d
    ;;
  install)
    DRIVE_ARGS=(-drive if=ide,index=0,file="$DISK",format=qcow2 -drive media=cdrom,file="$BOOT_ISO",readonly=on)
    BOOT_ORDER=d
    ;;
  disk)
    DRIVE_ARGS=(-drive if=ide,index=0,file="$DISK",format=qcow2)
    BOOT_ORDER=c
    ;;
esac

if [ "${REACTOS_BRIDGE:-1}" = "1" ] && [ "$MODE" != "install" ]; then
  mkdir -p "$BRIDGE_DIR"
  if [ -f "$DIR/shared/psi.exe" ]; then
    :
  elif [ -x "$DIR/build-psi.sh" ]; then
    "$DIR/build-psi.sh"
  fi
  if [ -f "$DIR/../.env.local" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$DIR/../.env.local"
    set +a
  fi
  pkill -f "$DIR/psi-http-proxy.py --port 18080" 2>/dev/null || true
  "$DIR/psi-http-proxy.py" --port 18080 > "$DIR/bridge.log" 2>&1 &
  DRIVE_ARGS+=(-drive "file=fat:rw:$SHARED",format=raw,if=ide,index=1)
fi

exec qemu-system-i386 \
  "${KVM_FLAG[@]}" \
  -machine pc,accel="$ACCEL" \
  -smp "${REACTOS_SMP:-2}" -m "${REACTOS_MEM:-1024}" \
  "${DRIVE_ARGS[@]}" \
  -boot order="$BOOT_ORDER",menu=on \
  -netdev user,id=n0,hostfwd=tcp::3390-:3389 \
  -device rtl8139,netdev=n0 \
  -vga std \
  -device sb16 \
  -usb -device usb-tablet \
  -monitor unix:/tmp/reactos-qemu-monitor,server,nowait \
  -name "psi on ReactOS ($MODE)" \
  "${DISPLAY_ARGS[@]}"
