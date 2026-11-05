#!/usr/bin/env bash
# Pack the psi source tree + a setup script + the API key into an
# ISO9660 image that Haiku will auto-mount as /PSIGUEST.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
STAGE="$DIR/guest/stage"
OUT="$DIR/guest.iso"
ENV_FILE="$REPO/.env.local"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — need ANTHROPIC_API_KEY in it."
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY not set after sourcing $ENV_FILE"
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/psi"

# Copy the repo as plain files (no tar/gzip — smaller surface for the
# guest to fail on, and Haiku's ISO9660+Rock Ridge handles them
# directly). Skip pi-mono (~680MB of reference code), build outputs,
# sessions, the haiku dir itself, .git, and the env file.
rsync -a \
  --exclude='/haiku' \
  --exclude='/pi-mono' \
  --exclude='/build' \
  --exclude='/result' \
  --exclude='/result-*' \
  --exclude='/sessions' \
  --exclude='/i686-transcripts' \
  --exclude='.env.local' \
  --exclude='/.git' \
  --exclude='__pycache__' \
  --exclude='/apr221504.jsonl' \
  "$REPO"/ "$STAGE/psi/"

# Ship the key in a separate file the setup script sources.
cat > "$STAGE/psi-env" <<EOF
export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
${OPENROUTER_API_KEY:+export OPENROUTER_API_KEY=$OPENROUTER_API_KEY}
EOF
chmod 600 "$STAGE/psi-env"

# Copy the active helper scripts. These get used via a single
# VNC-typed command:   sh /PSIGUEST/go
# `go` dispatches to ssh-bootstrap / fix-boot / install-psi based on
# current phase (see haiku/guest/go for the state machine).
cp "$DIR/guest/go"              "$STAGE/go"
cp "$DIR/guest/ssh-bootstrap.sh" "$STAGE/ssh-bootstrap.sh"
cp "$DIR/guest/fix-boot.sh"      "$STAGE/fix-boot.sh"
cp "$DIR/guest/install-psi.sh"   "$STAGE/install-psi.sh"
chmod +x "$STAGE/go" "$STAGE/ssh-bootstrap.sh" "$STAGE/fix-boot.sh" "$STAGE/install-psi.sh"

# Legacy helpers kept for reference.
cp "$DIR/guest/setup.sh"         "$STAGE/setup.sh"
cp "$DIR/guest/ssh-setup.sh"     "$STAGE/ssh-setup.sh"
cp "$DIR/guest/UserBootscript"   "$STAGE/UserBootscript"
chmod +x "$STAGE/setup.sh" "$STAGE/ssh-setup.sh" "$STAGE/UserBootscript"

# Ship argtable3 amalgamation (not packaged on HaikuPorts — only
# argtable2 is). install-psi.sh compiles it into a static lib and
# installs into ~/config/non-packaged so -largtable3 + <argtable3.h>
# resolve. We fetch it on demand from upstream (see
# fetch-argtable3.sh) rather than vendoring ~224 KB in the repo.
ARGT_CACHE="$DIR/downloads/argtable3"
if [ ! -f "$ARGT_CACHE/argtable3.c" ] || [ ! -f "$ARGT_CACHE/argtable3.h" ]; then
  bash "$DIR/fetch-argtable3.sh"
fi
cp "$ARGT_CACHE/argtable3.c" "$STAGE/argtable3.c"
cp "$ARGT_CACHE/argtable3.h" "$STAGE/argtable3.h"

# Ship a psi source tarball at a well-known path so install-psi.sh
# doesn't need wget-from-host. The rsync above already put the source
# under /PSIGUEST/psi/ — make a gzipped tarball too for convenience
# (install-psi.sh prefers tgz since tar on Haiku doesn't like ./ paths).
( cd "$STAGE" && tar --transform='s,^psi/,,' -czf psi-src.tgz psi )

# Ship the Linux-musl static psi binaries (i686 + x86_64). These are
# Linux ELFs — they will NOT run on Haiku's kernel, but the user asked
# to include them in the image for inspection / keeping around.
mkdir -p "$STAGE/linux-static"
if [ -f "$REPO/result-i686/bin/psi" ]; then
  cp -L "$REPO/result-i686/bin/psi" "$STAGE/linux-static/psi-i686"
fi
if [ -f "$REPO/result-x86_64/bin/psi" ]; then
  cp -L "$REPO/result-x86_64/bin/psi" "$STAGE/linux-static/psi-x86_64"
fi
cat > "$STAGE/linux-static/README.txt" <<'EOF'
These are Linux/musl static ELFs. They will not execute on Haiku's
kernel — Haiku has no Linux ABI shim. Kept here for reference and in
case you want to scp them back out to a Linux host.
EOF

# Build the ISO.
ISO_TOOL=""
if command -v mkisofs >/dev/null 2>&1; then ISO_TOOL=mkisofs; fi
if [ -z "$ISO_TOOL" ] && command -v genisoimage >/dev/null 2>&1; then ISO_TOOL=genisoimage; fi
if [ -z "$ISO_TOOL" ] && command -v xorriso >/dev/null 2>&1; then ISO_TOOL="xorriso -as mkisofs"; fi
if [ -z "$ISO_TOOL" ]; then
  echo "Need mkisofs, genisoimage, or xorriso installed."
  exit 1
fi

$ISO_TOOL -V PSIGUEST -J -r -o "$OUT" "$STAGE"
echo "Built $OUT"
