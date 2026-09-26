#!/bin/bash
# Replace /tmp/ext curl headers with the 8.4 source headers, then
# rebuild psi against the new libcurl. The binary psi had was linked
# against 8.19 curl, which ABI-mismatches our rebuilt 8.4 libcurl.
set +e

# 1. Copy 8.4 public headers
SRC=/tmp/curl-src/curl-8.4.0/include/curl
DST=/tmp/ext/develop/headers/curl
rm -rf "$DST"
mkdir -p "$DST"
for f in "$SRC"/*.h; do
  cat "$f" > "$DST/$(basename $f)"
done
ls "$DST/"

# 2. Rebuild psi with same env as before
export PATH=/tmp/ext/bin:/tmp/ext/develop/tools/bin:/boot/system/bin:/bin
export LIBRARY_PATH=/tmp/curl-out/lib:/tmp/ext/lib:/tmp/ext/develop/lib:/boot/system/lib:/boot/system/develop/lib

cd /var/psi
wget -q -O /tmp/mk.sh http://10.0.2.2:8765/mk.sh
bash /tmp/mk.sh 2>&1 | tail -30

echo "--- psi run ---"
./build/psi --version
