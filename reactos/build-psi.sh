#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$DIR/shared"
mkdir -p "$SHARED/bridge"

MCFG_OUT="$(nix eval --raw nixpkgs#pkgsCross.mingw32.windows.mcfgthreads.outPath)"

nix shell \
  nixpkgs#pkgsCross.mingw32.stdenv.cc \
  nixpkgs#pkgsCross.mingw32.windows.mcfgthreads \
  nixpkgs#pkgsCross.mingw32.windows.mcfgthreads.dev \
  -c \
  i686-w64-mingw32-gcc -std=c99 -O2 -Wall -Wextra \
    -L"$MCFG_OUT/lib" -static \
    -o "$SHARED/psi.exe" "$DIR/psi-client/main.c" -lws2_32

echo "built $SHARED/psi.exe"
