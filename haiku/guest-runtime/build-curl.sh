#!/bin/bash
# Build a fresh libcurl against Haiku's system openssl 3.0.14.
# Outputs libcurl.so.4 into /tmp/curl-out/lib.
set +e

EXT=/tmp/ext
SYS=/boot/system
OUT=/tmp/curl-out

export PATH=$EXT/bin:$EXT/develop/tools/bin:$SYS/bin:/bin
export C_INCLUDE_PATH="$EXT/develop/headers:$EXT/develop/headers/posix:$EXT/develop/headers/os:$EXT/develop/headers/os/app:$EXT/develop/headers/os/support:$EXT/develop/headers/os/kernel:$EXT/develop/headers/os/interface:$EXT/develop/headers/bsd"
export LIBRARY_PATH="$EXT/lib:$EXT/develop/lib:$EXT/develop/tools/lib:$SYS/lib:$SYS/develop/lib"
# gcc on Haiku needs -B pointing at startup objects + ld search paths
# explicitly; without them ./configure's link test fails.
export CC="gcc -B$EXT/bin/ -B$EXT/develop/lib/ -L$EXT/develop/lib -L$EXT/lib -L$SYS/lib -L$SYS/develop/lib"

# Extract openssl3_devel to /tmp/ext so we have headers + libs for 3.0.14.
if [ ! -f "$EXT/develop/headers/openssl/ssl.h" ] && [ ! -f "$EXT/develop/headers/openssl3/openssl/ssl.h" ]; then
  echo "=== extract openssl3_devel ==="
  pkgman install -y openssl3_devel || true
  for p in $SYS/packages/openssl3-*.hpkg $SYS/packages/openssl3_devel-*.hpkg; do
    [ -f "$p" ] && package extract -C "$EXT" "$p"
  done
fi

# Fetch curl source.
echo "=== fetch curl ==="
mkdir -p /tmp/curl-src
cd /tmp/curl-src
wget -q -O curl.tar.gz http://10.0.2.2:8765/curl.tar.gz
rm -rf curl-8.4.0
tar xzf curl.tar.gz
cd curl-8.4.0

echo "=== configure curl ==="
# Minimal config: shared libcurl, openssl backend, zlib, nghttp2 optional.
# openssl3_devel headers land under develop/headers; libs in lib/.
# Pass CPPFLAGS + LDFLAGS explicitly since --with-openssl=PATH expects
# a single-prefix layout that /tmp/ext doesn't match.
CPPFLAGS="-I$EXT/develop/headers" \
LDFLAGS="-L$EXT/lib -L$EXT/develop/lib -L$SYS/lib -L$SYS/develop/lib -B$EXT/bin/ -B$EXT/develop/lib/" \
LIBS="-lssl -lcrypto" \
./configure \
  --prefix="$OUT" \
  --with-openssl \
  --with-zlib \
  --with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem \
  --without-libidn2 --without-libpsl --without-brotli --without-zstd \
  --without-libssh2 --without-libssh --without-nghttp2 \
  --without-ngtcp2 --without-nghttp3 --without-quiche --without-msh3 \
  --disable-ldap --disable-ldaps --disable-ntlm-wb --disable-manual \
  --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
  --disable-pop3 --disable-imap --disable-smb --disable-smtp \
  --disable-gopher --disable-mqtt --disable-static \
  2>&1 | tail -30

echo "=== make curl (lib only) ==="
# Just build libcurl, skip the curl executable (avoids libtool .la race).
make -j1 -C lib 2>&1 | tail -20

echo "=== install libcurl ==="
make -C lib install 2>&1 | tail -10
# Also install public headers.
make -C include install 2>&1 | tail -5
ls -la "$OUT/lib/libcurl.so"*

echo "=== test psi with new libcurl ==="
export LIBRARY_PATH="$OUT/lib:$LIBRARY_PATH"
cd /var/psi
./build/psi --help 2>&1 | head -20
