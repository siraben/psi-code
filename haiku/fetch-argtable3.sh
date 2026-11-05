#!/usr/bin/env bash
# Fetch the argtable3 single-file amalgamation from upstream if it
# isn't already cached locally. argtable3 isn't in HaikuPorts (only
# the older argtable2 is), so the Haiku build needs this file.
# Kept out of the repo because it's 224 KB of third-party code we
# can reproducibly fetch from a pinned upstream release.
#
# After running, the files land under
#   haiku/downloads/argtable3/argtable3.{c,h}
# which haiku/build-guest-cd.sh picks up.
set -euo pipefail

VER='v3.2.2.f25c624'
BASE_URL="https://github.com/argtable/argtable3/releases/download/${VER}/argtable-${VER}-amalgamation.tar.gz"
SHA256_C='18fdf9d9d48efef456da82634189f3dd9fc9f81f11d2ff319a3e084b63e5d6c2'
SHA256_H='8efb56fbef4240ed4494810de810df732de449e80ad21f9fa251fc01f503a829'

DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE="$DIR/downloads/argtable3"
mkdir -p "$CACHE"

C="$CACHE/argtable3.c"
H="$CACHE/argtable3.h"

if [ -f "$C" ] && [ -f "$H" ] \
    && [ "$(sha256sum "$C" | awk '{print $1}')" = "$SHA256_C" ] \
    && [ "$(sha256sum "$H" | awk '{print $1}')" = "$SHA256_H" ]; then
  echo "argtable3 $VER already cached at $CACHE"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching argtable3 $VER amalgamation"
curl -fsSL "$BASE_URL" -o "$TMP/argtable.tar.gz"
tar -xzf "$TMP/argtable.tar.gz" -C "$TMP"

# Archive layout: argtable-<VER>-amalgamation/{argtable3.c,argtable3.h,...}
cp "$TMP"/*/argtable3.c "$C"
cp "$TMP"/*/argtable3.h "$H"

GOT_C=$(sha256sum "$C" | awk '{print $1}')
GOT_H=$(sha256sum "$H" | awk '{print $1}')
if [ "$GOT_C" != "$SHA256_C" ] || [ "$GOT_H" != "$SHA256_H" ]; then
  echo "sha256 mismatch!"
  echo "argtable3.c: expected $SHA256_C, got $GOT_C"
  echo "argtable3.h: expected $SHA256_H, got $GOT_H"
  exit 1
fi

echo "argtable3 $VER fetched to $CACHE"
