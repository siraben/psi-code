#!/bin/bash
set +e
cd /var/psi
EXT=/tmp/ext
NP=/boot/home/config/non-packaged
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
HINC="$HINC -I$EXT/develop/headers/bsd"
HINC="$HINC -I$EXT/develop/headers/lua54"

# Use C_INCLUDE_PATH so ALL gcc invocations — including the Makefile's
# embed_lua host tool which doesn't propagate CPPFLAGS — pick up the
# Haiku headers.
export C_INCLUDE_PATH="$EXT/develop/headers:$EXT/develop/headers/posix:$EXT/develop/headers/os:$EXT/develop/headers/os/app:$EXT/develop/headers/os/support:$EXT/develop/headers/os/kernel:$EXT/develop/headers/os/interface:$EXT/develop/headers/os/storage:$EXT/develop/headers/os/drivers:$EXT/develop/headers/os/locale:$EXT/develop/headers/bsd:$EXT/develop/headers/lua54:$NP/develop/headers"

# LIBRARY_PATH must include Haiku's system lib dirs so embed_lua's
# linker step can find crt*.o, libroot, libgcc_s, etc.  Makefile rule
# doesn't propagate LDFLAGS to that target.
export LIBRARY_PATH="/tmp/curl-out/lib:$EXT/lib:$EXT/develop/lib:$EXT/develop/tools/lib:$NP/develop/lib:/boot/system/develop/lib:/boot/system/lib"

make clean
# Let Makefile compute PSI_LUA_BOOT_FILE define itself (it already
# handles the quoting); we just override LOCAL_CPPFLAGS minus the
# pkg-config part, and override LOCAL_LDFLAGS to use -l flags.
make -j1 "CC=gcc -B$EXT/bin/ -B$EXT/develop/lib/ -L/tmp/curl-out/lib -L$EXT/develop/lib -L$EXT/lib -L$NP/develop/lib -L/boot/system/lib -L/boot/system/develop/lib" \
  LUA_BOOT_FILE=/var/psi/lua/boot.lua \
  BASE_CFLAGS='-std=gnu99 -Wall' \
  CPPFLAGS="-I$NP/develop/headers $HINC -D_GNU_SOURCE" \
  LOCAL_CPPFLAGS='-Iinclude -DPSI_LUA_BOOT_FILE="\"/var/psi/lua/boot.lua\""' \
  LOCAL_LDFLAGS="-L$NP/develop/lib -L$EXT/lib -L$EXT/develop/lib -llua -lcjson -ledit -lcurl -lz -largtable3 -lncurses -lpthread" \
  2>&1 | tail -40

echo "--- result ---"
ls -la build/psi 2>&1
file build/psi 2>&1
