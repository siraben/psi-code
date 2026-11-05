#!/usr/bin/env bash
# Build a TinyCorePure64 initrd with psi baked in, plus a persistent data disk.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ISO="$HERE/downloads/TinyCorePure64-current.iso"
PSI_BIN="${PSI_BIN:-$REPO/result-x86_64-new/bin/psi}"
AUTH_SRC="${AUTH_SRC:-$HOME/.config/psi/auth.json}"
CA_SRC="${CA_SRC:-/etc/ssl/certs/ca-bundle.crt}"
ENV_LOCAL="${ENV_LOCAL:-$REPO/.env.local}"
PSI_MODEL="${PSI_MODEL:-claude-opus-5}"

OVERLAY="$HERE/overlay"
DISK="$HERE/disk.qcow2"
DISK_SIZE="${DISK_SIZE:-8G}"

for f in "$ISO" "$PSI_BIN" "$AUTH_SRC" "$CA_SRC"; do
	[ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

echo "==> extracting kernel + initrd from ISO"
isoinfo -R -i "$ISO" -x /boot/vmlinuz64     > "$HERE/vmlinuz64"
isoinfo -R -i "$ISO" -x /boot/corepure64.gz > "$HERE/core64.gz"

echo "==> staging psi overlay"
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/opt/psi" "$OVERLAY/etc/profile.d"

install -m 0755 "$PSI_BIN" "$OVERLAY/opt/psi/psi"
install -m 0600 "$AUTH_SRC" "$OVERLAY/opt/psi/auth.json"
install -m 0644 "$CA_SRC"   "$OVERLAY/opt/psi/ca-bundle.crt"

cat > "$OVERLAY/opt/psi/settings.json" <<EOF
{
  "defaults": {
    "provider": "anthropic",
    "model": "$PSI_MODEL"
  }
}
EOF
chmod 0644 "$OVERLAY/opt/psi/settings.json"

cat > "$OVERLAY/etc/profile.d/psi.sh" <<'EOF'
# psi environment
export PATH="/opt/psi:$PATH"
export SSL_CERT_FILE=/opt/psi/ca-bundle.crt
export CURL_CA_BUNDLE=/opt/psi/ca-bundle.crt
export TERM=xterm-256color
EOF

# API keys live in a group-readable file the profile sources, so they are not
# exposed as widely as /etc/profile.d itself.
if [ -f "$ENV_LOCAL" ]; then
	grep -E '^export (ANTHROPIC|OPENROUTER|KIMI)_API_KEY=' "$ENV_LOCAL" \
		> "$OVERLAY/opt/psi/env.sh" || true
	chmod 0600 "$OVERLAY/opt/psi/env.sh"
	cat >> "$OVERLAY/etc/profile.d/psi.sh" <<'EOF'
[ -r /opt/psi/env.sh ] && . /opt/psi/env.sh
EOF
fi
chmod 0644 "$OVERLAY/etc/profile.d/psi.sh"

# Larger, legible fonts and a usable scrollback over VNC.
cat > "$OVERLAY/opt/psi/Xdefaults" <<'EOF'
aterm*font: 9x15
aterm*background: #101418
aterm*foreground: #d8dee9
aterm*saveLines: 5000
aterm*scrollBar: true
aterm*scrollBar_right: true
aterm*cursorColor: #88c0d0
EOF
chmod 0644 "$OVERLAY/opt/psi/Xdefaults"

# bootlocal.sh runs in the background at the end of boot (from bootsync.sh),
# after tc-config has created the user and mounted any persistent /home.
cat > "$OVERLAY/opt/bootlocal.sh" <<'EOF'
#!/bin/sh
# put other system startup commands here
TCUSER="$(cat /etc/sysconfig/tcuser 2>/dev/null)"
[ -n "$TCUSER" ] || TCUSER=tc
HOMEDIR="/home/$TCUSER"

# psi on PATH for non-login shells too
mkdir -p /usr/local/bin
ln -sf /opt/psi/psi /usr/local/bin/psi

# Seed config once; never clobber a token psi has since refreshed or a
# settings file the user has since edited.
mkdir -p "$HOMEDIR/.config/psi"
for f in auth.json settings.json; do
	if [ ! -f "$HOMEDIR/.config/psi/$f" ] && [ -f "/opt/psi/$f" ]; then
		cp "/opt/psi/$f" "$HOMEDIR/.config/psi/$f"
	fi
done
[ -f /opt/psi/Xdefaults ] && cp /opt/psi/Xdefaults "$HOMEDIR/.Xdefaults"
chown -R "$TCUSER":staff "$HOMEDIR/.config" "$HOMEDIR/.Xdefaults" 2>/dev/null
chmod 0700 "$HOMEDIR/.config/psi"
chmod 0600 "$HOMEDIR/.config/psi/auth.json"

# API keys: readable by the staff group (which tc is in), not by the world.
if [ -f /opt/psi/env.sh ]; then
	chown root:staff /opt/psi/env.sh
	chmod 0640 /opt/psi/env.sh
fi

# Screen blanking is disruptive over VNC; the session is remote-only.
if [ -n "$(pgrep Xfbdev 2>/dev/null)" ] || [ -n "$(pgrep Xvesa 2>/dev/null)" ]; then
	DISPLAY=:0 xset s off -dpms 2>/dev/null
fi

# Host-side control channel: a root shell on the second serial port, which
# run-vm.sh exposes as a unix socket. Used for smoke tests and debugging.
if [ -c /dev/ttyS1 ]; then
	setsid /bin/sh </dev/ttyS1 >/dev/ttyS1 2>&1 &
fi
EOF
chmod 0755 "$OVERLAY/opt/bootlocal.sh"

echo "==> packing overlay cpio"
( cd "$OVERLAY" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$HERE/psi-overlay.gz"

echo "==> building combined initrd"
cat "$HERE/core64.gz" "$HERE/psi-overlay.gz" > "$HERE/psi-core64.gz"

if [ ! -f "$DISK" ]; then
	echo "==> creating $DISK_SIZE persistent disk"
	qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

ls -la "$HERE/vmlinuz64" "$HERE/psi-core64.gz" "$DISK"
echo "==> done"
