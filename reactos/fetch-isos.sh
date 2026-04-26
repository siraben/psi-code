#!/usr/bin/env bash
# Fetch the current ReactOS 0.4.15 release images.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADS="$DIR/downloads"
mkdir -p "$DOWNLOADS"

VERSION="${REACTOS_VERSION:-0.4.15}"
BUILD="${REACTOS_BUILD:-release-1-gdbb43bbaeb2}"
BASE="https://downloads.sourceforge.net/project/reactos/ReactOS/$VERSION"
MIRROR="${REACTOS_MIRROR:-nchc}"

fetch_zip() {
  local kind="$1"
  local zip="$DOWNLOADS/ReactOS-$VERSION-$BUILD-x86-$kind.zip"
  local iso="$DOWNLOADS/ReactOS-$VERSION-$BUILD-x86-$kind.iso"
  if [ "$kind" = "iso" ]; then
    iso="$DOWNLOADS/ReactOS-$VERSION-$BUILD-x86.iso"
  fi
  local url="$BASE/ReactOS-$VERSION-$BUILD-x86-$kind.zip?use_mirror=$MIRROR"

  if [ ! -f "$iso" ]; then
    if [ ! -f "$zip" ]; then
      echo "downloading $url"
      curl -L --fail --retry 3 --speed-time 30 --speed-limit 10240 -o "$zip" "$url"
    fi
    echo "extracting $(basename "$zip")"
    unzip -o -d "$DOWNLOADS" "$zip" '*.iso'
  fi

  [ -f "$iso" ] || {
    echo "expected $iso after extraction" >&2
    exit 1
  }
}

fetch_zip live
fetch_zip iso

echo "ReactOS ISOs are ready in $DOWNLOADS"
