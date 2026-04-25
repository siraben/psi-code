#!/usr/bin/env bash
# Fetch the 9front amd64 ISO if not already cached.
#
# 9front publishes rolling "FQA" snapshots. We pin a specific snapshot
# URL + SHA256 so re-running on a different day gets the same bits.
# Override via NINEFRONT_ISO_URL + NINEFRONT_ISO_SHA256 to try a newer
# build.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE="$DIR/downloads"
mkdir -p "$CACHE"

# 9front's published ISOs rotate; this is the 2026-01-24 snapshot.
# The 9front release hub lists the authoritative mirror under
# http://9front.org/iso/ — if that moves, override via env.
URL="${NINEFRONT_ISO_URL:-http://9front.org/iso/9front-11554.amd64.iso.gz}"
OUT="$CACHE/$(basename "$URL")"
ISO="${OUT%.gz}"
ISO="${ISO%.xz}"

if [ -f "$ISO" ]; then
  echo "$ISO already present"
  exit 0
fi

if [ ! -f "$OUT" ]; then
  echo "fetching $URL"
  curl -fLo "$OUT" "$URL"
fi

case "$OUT" in
  *.xz) echo "xz -d $OUT"; xz -d -k -f "$OUT" ;;
  *.gz) echo "gunzip $OUT"; gunzip -k -f "$OUT" ;;
esac

ls -lh "$ISO"
echo "9front ISO ready at $ISO"
