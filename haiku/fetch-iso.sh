#!/usr/bin/env bash
# Download Haiku R1/beta5 x86_64 anyboot ISO, resume-safe, checksum-verified.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_DIR="$DIR/downloads"
ISO="$ISO_DIR/haiku-r1beta5-x86_64-anyboot.iso"
URL="https://mirrors.tnonline.net/haiku/haiku-release/r1beta5/haiku-r1beta5-x86_64-anyboot.iso"
SHA256="22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69"

mkdir -p "$ISO_DIR"

if [ -f "$ISO" ]; then
  have=$(sha256sum "$ISO" | awk '{print $1}')
  if [ "$have" = "$SHA256" ]; then
    echo "ISO present and verified: $ISO"
    exit 0
  fi
  echo "ISO present but checksum differs; re-downloading with resume."
fi

curl -L -C - -o "$ISO" "$URL"

have=$(sha256sum "$ISO" | awk '{print $1}')
if [ "$have" != "$SHA256" ]; then
  echo "CHECKSUM MISMATCH"
  echo "  got:      $have"
  echo "  expected: $SHA256"
  exit 1
fi
echo "ISO downloaded and verified: $ISO"
