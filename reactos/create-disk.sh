#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/disk.qcow2"
SIZE="${REACTOS_DISK_SIZE:-8G}"

if [ -f "$DISK" ]; then
  echo "$DISK already exists"
  exit 0
fi

qemu-img create -f qcow2 "$DISK" "$SIZE"
echo "created $DISK ($SIZE)"
