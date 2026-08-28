#!/bin/bash
# Runs inside Haiku. Mount point is /PSIGUEST (volume label).

SRC=/PSIGUEST
DST=/boot/home/psi
PROFILE=/boot/home/config/settings/profile
NP=/boot/home/config/non-packaged

say() { printf '\n=== %s ===\n' "$*"; }

say "1/6  copy psi source to $DST"
rm -rf "$DST"
cp -r "$SRC/psi" "$DST" || { echo "cp failed"; exit 1; }
chmod -R u+w "$DST"

say "2/6  embed ANTHROPIC_API_KEY into $PROFILE"
mkdir -p "$(dirname "$PROFILE")"
NEW="$PROFILE.new.$$"
: > "$NEW"
if [ -f "$PROFILE" ]; then
  awk '/^# psi-env$/{skip=1;next} /^# \/psi-env$/{skip=0;next} !skip' \
    "$PROFILE" >> "$NEW"
fi
{
  echo '# psi-env'
  cat "$SRC/psi-env"
  echo '# /psi-env'
} >> "$NEW"
mv "$NEW" "$PROFILE"
# shellcheck disable=SC1090
. "$SRC/psi-env"
echo "API key length: ${#ANTHROPIC_API_KEY}"

say "3/6  install devel packages via pkgman"
# argtable3 is NOT in HaikuPorts; we build and install it ourselves
# below. The other names are the actual HaikuPorts x86_64 names.
pkgman install -y \
  gcc \
  haiku_devel \
  pkgconfig \
  make \
  lua_devel \
  cjson_devel \
  curl_devel \
  libedit_devel \
  ncurses6_devel \
  zlib_devel

say "4/6  build argtable3 (amalgamation) and install into $NP"
mkdir -p "$NP/develop/lib" "$NP/develop/headers"
# Haiku's C compiler is named gcc (no cc symlink).
gcc -O2 -c "$SRC/vendor/argtable3/argtable3.c" -o /tmp/argtable3.o \
  -I"$SRC/vendor/argtable3" || { echo "argtable3 compile failed"; exit 1; }
ar rcs "$NP/develop/lib/libargtable3.a" /tmp/argtable3.o
cp "$SRC/vendor/argtable3/argtable3.h" "$NP/develop/headers/argtable3.h"
rm -f /tmp/argtable3.o

say "5/6  build psi"
cd "$DST" || exit 1
# CC=gcc because Haiku ships no cc symlink; pkg-config sometimes
# reports libs through the `cmd:` provides namespace so point
# PKG_CONFIG at gcc's wrapper explicitly.
CC=gcc \
CPPFLAGS="-I$NP/develop/headers" \
LDFLAGS="-L$NP/develop/lib" \
make CC=gcc 2>&1 | tail -60
if [ ! -x "$DST/build/psi" ]; then
  echo "build failed — see above"
  exit 1
fi

say "6/6  smoke"
"$DST/build/psi" --help || true

cat <<EOF

----------------------------------------------
psi:   $DST/build/psi
key:   embedded in $PROFILE (new Terminals inherit it)
run:   $DST/build/psi
----------------------------------------------
EOF
