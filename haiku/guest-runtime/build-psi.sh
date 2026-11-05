#!/bin/bash
# All-in-one build for psi on Haiku, self-contained script.

set +e
EXT=/tmp/ext
NP=/boot/home/config/non-packaged

# Binutils extract (idempotent)
if [ ! -f "$EXT/bin/as" ]; then
  package extract -C "$EXT" /boot/system/packages/binutils-*.hpkg
fi

# Env
export PATH=$EXT/bin:$EXT/develop/tools/bin:/boot/system/bin
unset C_INCLUDE_PATH
export LIBRARY_PATH=$EXT/lib:$EXT/develop/tools/lib:/boot/system/lib

# Haiku include flags common set
HINC="-I$EXT/develop/headers"
HINC="$HINC -I$EXT/develop/headers/posix"
HINC="$HINC -I$EXT/develop/headers/os"
HINC="$HINC -I$EXT/develop/headers/os/app"
HINC="$HINC -I$EXT/develop/headers/os/support"
HINC="$HINC -I$EXT/develop/headers/os/kernel"
HINC="$HINC -I$EXT/develop/headers/os/interface"
HINC="$HINC -I$EXT/develop/headers/os/storage"
HINC="$HINC -I$EXT/develop/headers/os/drivers"
HINC="$HINC -I$EXT/develop/headers/os/locale"
HINC="$HINC -I$EXT/develop/headers/os/net"
HINC="$HINC -I$EXT/develop/headers/os/package"
HINC="$HINC -I$EXT/develop/headers/bsd"
FLAGS="-D_GNU_SOURCE -D_DEFAULT_SOURCE -std=gnu99 -Wno-error=old-style-definition -Wno-old-style-definition"

mkdir -p "$NP/develop/lib" "$NP/develop/headers"

echo "=== 1. build argtable3 ==="
echo "gcc: $(which gcc), as: $(which as)"
gcc -B $EXT/bin/ -O2 -c /tmp/argtable3.c -o /tmp/argtable3.o -I/tmp $HINC $FLAGS 2>&1 | tail -20
if [ ! -f /tmp/argtable3.o ]; then
  echo "argtable3 compile failed, aborting"
  return 1 2>/dev/null; exit 1
fi
ar rcs "$NP/develop/lib/libargtable3.a" /tmp/argtable3.o
cp /tmp/argtable3.h "$NP/develop/headers/argtable3.h"
echo "argtable3 OK"

echo "=== 2. fetch psi source ==="
wget -q -O /tmp/psi-src.tgz http://10.0.2.2:8765/psi-src.tgz
rm -rf /boot/home/psi
mkdir -p /boot/home/psi
cd /boot/home/psi
tar xzf /tmp/psi-src.tgz
ls | head

echo "=== 3. build psi ==="
# The Makefile uses pkg-config; point it at extracted .pc files
export PKG_CONFIG_PATH=$EXT/develop/lib/pkgconfig
make CC=gcc \
  CPPFLAGS="-I$NP/develop/headers $HINC $FLAGS -B $EXT/bin/" \
  LDFLAGS="-L$NP/develop/lib -L$EXT/lib -L$EXT/develop/lib" \
  LOCAL_CPPFLAGS= \
  2>&1 | tail -60

echo "=== 4. result ==="
if [ -x ./build/psi ]; then
  ls -la ./build/psi
  file ./build/psi
  echo "--- help ---"
  ./build/psi --help 2>&1 | head -30
else
  echo "psi not built"
fi
