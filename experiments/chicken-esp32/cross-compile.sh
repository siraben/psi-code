#!/usr/bin/env bash
# Cross-compile a tiny Chicken-Scheme program to xtensa-esp32-elf.
#
# Status: the user-program compiles cleanly. The runtime (libchicken)
# does NOT — it pulls in setitimer, timezone, C_resolve_executable_pathname,
# poll(), sigaction(), getrusage(), dlopen(), and a handful of other
# POSIX-hosted bits that newlib in xtensa-esp-elf doesn't provide. See
# README.md for a full account of the trajectory.
#
# Run: bash cross-compile.sh
# Requires: docker, host chicken (brew install chicken).

set -euo pipefail

CHICKEN_VERSION=${CHICKEN_VERSION:-5.4.0}
WORK=${WORK:-/tmp/chicken-esp}
SRC=${SRC:-/tmp/chicken-build}

mkdir -p "$WORK/include"
if [ ! -d "$SRC/chicken-$CHICKEN_VERSION" ]; then
  mkdir -p "$SRC"
  curl -fsSL "https://code.call-cc.org/releases/$CHICKEN_VERSION/chicken-$CHICKEN_VERSION.tar.gz" \
    | tar -xzf - -C "$SRC"
fi

# 1. csc → C on the host (relies on host chicken).
csc -c -t "$(dirname "$0")/hello.scm" -o "$WORK/hello.c"

# 2. Cross-compile the user program for xtensa.
cp /opt/homebrew/Cellar/chicken/$CHICKEN_VERSION/include/chicken/*.h "$WORK/include/" 2>/dev/null || true

XTGCC=/opt/esp/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-gcc

docker run --rm -v "$WORK":/work -v "$SRC/chicken-$CHICKEN_VERSION":/chicken espressif/idf:v5.5 bash -c "
  set -e
  cd /work
  echo '== compiling hello.c (csc-output) =='
  $XTGCC -mlongcalls -fno-builtin -Os -ffunction-sections -fdata-sections \
    -DNO_DLOAD2 -DNO_POSIX_POLL -DC_BIG_ENDIAN=0 \
    -I/work/include -I/chicken \
    -w -c hello.c -o hello.o
  ls -la hello.o
  echo '== attempting libchicken runtime.c =='
  cp /chicken/runtime.c .
  $XTGCC -mlongcalls -fno-builtin -Os -ffunction-sections -fdata-sections \
    -DNO_DLOAD2 -DNO_POSIX_POLL -DC_BIG_ENDIAN=0 \
    -I/work/include -I/chicken \
    -w -c runtime.c -o runtime.o 2>&1 | head -25 || true
  ls -la runtime.o 2>&1 || echo '(runtime.o not produced — see errors above)'
"
