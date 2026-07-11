#!/bin/bash
# Install psi on a disk-booted Haiku r1beta5. Assumes:
#   * SSH'd in as `user`
#   * source available at one of (first wins):
#       - /PSIGUEST/psi-src.tgz + /PSIGUEST/argtable3.{c,h}
#       - /tmp/psi-src.tgz      + /tmp/argtable3.{c,h}
#       - otherwise wget'd from 10.0.2.2:8765
#   * api key available in env ANTHROPIC_API_KEY (we persist it to profile)
#
# Does the complete Phase-3.5/3.6 "after SSH is up" sequence in one go:
#   1. pkgman install all deps (incl. the openssl3-3.5.5 upgrade)
#   2. reboot to activate the new haiku/openssl3/libssh2
#   3. (on second invocation, when /tmp/psi-boot-done exists) build psi
#
# Rather than juggle two scripts, call this once, reboot when it tells
# you to, then call it again.

set -e

MARKER=/boot/home/.psi-deps-installed
PROF=/boot/home/config/settings/profile

say() { printf '\n=== %s ===\n' "$*"; }

if [ ! -f "$MARKER" ]; then
  say "phase 1: install dev packages"
  # Toolchain first — triggers a staged haiku runtime update.
  pkgman install -y gcc gcc_syslibs_devel haiku_devel binutils
  # Everything else psi needs.  Explicit `openssl3` (not just _devel)
  # forces the 3.5.5 upgrade; stock r1beta5 ships 3.0.14 which libcurl
  # 8.19 cannot link against (missing OPENSSL_3.2.0 symbol version).
  pkgman install -y \
      lua lua_devel cjson cjson_devel libedit_devel \
      ncurses6_devel zlib_devel pkgconfig \
      openssl3 openssl3_devel \
      curl_devel \
      nghttp2 nghttp2_devel libssh2_devel

  say "seed VESA mode 1920x1080 (matches run-vm-persist.sh HAIKU_RES)"
  mkdir -p /boot/home/config/settings/kernel/drivers
  cat > /boot/home/config/settings/kernel/drivers/vesa <<'VESA'
mode 1920 1080 32
VESA

  say "persist sshd via UserBootscript"
  mkdir -p /boot/home/config/settings/boot
  cat > /boot/home/config/settings/boot/UserBootscript <<'BOOT'
#!/bin/bash
LOG=/boot/home/userboot.log
exec >> "$LOG" 2>&1
echo "=== UserBootscript $(date) ==="
# Auto-mount PSIGUEST if its CD is attached — Tracker doesn't mount
# CDs on disk-boot, so /PSIGUEST/go needs this to be reachable.
mountvolume PSIGUEST >/dev/null 2>&1 || true
if ! pgrep -x sshd >/dev/null 2>&1 && [ -x /boot/system/bin/sshd ]; then
  cat > /tmp/sshd_config <<CFG
Port 2222
HostKey /boot/home/config/settings/ssh/hk_ed25519
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
AuthorizedKeysFile /boot/home/config/settings/ssh/authorized_keys /boot/home/.ssh/authorized_keys
PidFile /tmp/sshd.pid
Subsystem sftp internal-sftp
LogLevel INFO
CFG
  /boot/system/bin/sshd -f /tmp/sshd_config -E /tmp/sshd.log &
fi
BOOT
  chmod +x /boot/home/config/settings/boot/UserBootscript

  say "seed /boot/home/bin helpers (so 'go' works as a 2-char command)"
  mkdir -p /boot/home/bin
  for f in go ssh-bootstrap.sh fix-boot.sh install-psi.sh; do
    if [ -f "/PSIGUEST/$f" ]; then
      cp "/PSIGUEST/$f" "/boot/home/bin/$f"
      chmod +x "/boot/home/bin/$f"
    fi
  done

  say "persist ANTHROPIC_API_KEY in profile"
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && ! grep -q ANTHROPIC_API_KEY "$PROF" 2>/dev/null; then
    cat >> "$PROF" <<PROFEOF
export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'
export PATH=/boot/home/bin:/boot/home/config/non-packaged/bin:/boot/home/config/bin:/boot/system/non-packaged/bin:/boot/system/bin:/bin:/boot/system/apps:/boot/system/preferences
PROFEOF
  fi

  touch "$MARKER"
  say "REBOOT required — packages staged. After reboot, re-run this script."
  echo
  echo "  nohup /boot/system/bin/shutdown -r -q >/dev/null 2>&1 &"
  exit 0
fi

# Locate build inputs in this preference order:
#   /tmp      — user-pushed, wins so you can `scp psi-src.tgz :/tmp/`
#   /PSIGUEST — guest CD, stale if ISO wasn't rebuilt
#   host HTTP — last-resort fetch from 10.0.2.2:8765
find_input() {
  local name="$1"
  for p in "/tmp/$name" "/PSIGUEST/$name"; do
    [ -f "$p" ] && { echo "$p"; return; }
  done
  local dst="/tmp/$name"
  wget -q -O "$dst" "http://10.0.2.2:8765/$name" && \
    [ -s "$dst" ] && echo "$dst"
}

# --- phase 2: post-reboot, build psi ---
say "phase 2: build argtable3"
ARGT_C=$(find_input argtable3.c); ARGT_H=$(find_input argtable3.h)
[ -f "$ARGT_C" ] && [ -f "$ARGT_H" ] || { echo "argtable3 sources missing"; exit 1; }
NP=/boot/home/config/non-packaged
mkdir -p "$NP/develop/lib" "$NP/develop/headers"
cp "$ARGT_H" "$NP/develop/headers/argtable3.h"
# Build in a clean tmpdir. gcc needs argtable3.c and argtable3.h
# side-by-side (the amalgamation does `#include "argtable3.h"`).
BUILDDIR=$(mktemp -d)
cp -f "$ARGT_C" "$BUILDDIR/argtable3.c"
cp -f "$ARGT_H" "$BUILDDIR/argtable3.h"
(
  cd "$BUILDDIR"
  gcc -O2 -c argtable3.c -o argtable3.o
  ar rcs "$NP/develop/lib/libargtable3.a" argtable3.o
)
rm -rf "$BUILDDIR"

say "phase 2: stage psi source"
PSI_TGZ=$(find_input psi-src.tgz)
[ -f "$PSI_TGZ" ] || { echo "psi-src.tgz missing"; exit 1; }
rm -rf /boot/home/psi
mkdir -p /boot/home/psi
tar -xzf "$PSI_TGZ" -C /boot/home/psi

say "phase 2: drive gcc"
cd /boot/home/psi
mkdir -p build
CFLAGS="-O2 -std=gnu99 -Wall"
PKGS_CFLAGS="$(pkg-config --cflags lua5.4 libcjson libedit libcurl zlib ncursesw)"
PKGS_LIBS="$(pkg-config --libs   lua5.4 libcjson libedit libcurl zlib ncursesw)"
INC="-I./include -I$NP/develop/headers"
FLAGS="$CFLAGS $INC $PKGS_CFLAGS -DPSI_LUA_BOOT_FILE=\"/var/psi/lua/boot.lua\""
LDF="-L$NP/develop/lib $PKGS_LIBS -largtable3 -lpthread -lnetwork -lbsd"

# embed_lua (host tool)
gcc -O2 $(pkg-config --cflags zlib) -o build/embed_lua scripts/embed_lua.c $(pkg-config --libs zlib)
LUA_SOURCES="lua/boot.lua $(ls lua/psi/*.lua | sort)"
DOC_SOURCES="README.md $(ls docs/*.md 2>/dev/null | sort)"
./build/embed_lua $LUA_SOURCES > build/embedded_lua.c
./build/embed_lua --table=psi_embedded_docs_table --raw-keys $DOC_SOURCES > build/embedded_docs.c

for src in src/main.c src/core/abort.c src/core/agent.c src/core/common.c \
           src/core/anthropic.c src/core/http_async.c src/core/process.c \
           src/core/session.c src/runtime/cli.c src/runtime/print_mode.c \
           src/runtime/tui_mode.c src/lua/vm.c; do
  gcc $FLAGS -c "$src" -o "build/$(basename "$src" .c).o"
done
gcc $FLAGS -c build/embedded_lua.c  -o build/embedded_lua.o
gcc $FLAGS -c build/embedded_docs.c -o build/embedded_docs.o

gcc -o build/psi \
  build/main.o build/abort.o build/agent.o build/common.o \
  build/anthropic.o build/http_async.o build/process.o build/session.o \
  build/cli.o build/print_mode.o build/tui_mode.o build/vm.o \
  build/embedded_lua.o build/embedded_docs.o \
  $LDF

say "phase 2: install psi"
mkdir -p /boot/home/bin
cp build/psi /boot/home/bin/psi
chmod +x /boot/home/bin/psi

say "phase 2: smoke-test"
export PATH=/boot/home/bin:$PATH
psi --version
psi --help 2>&1 | head -1
echo
echo "Done. Try:  psi --agent='one word hello' --max-tokens=10"
