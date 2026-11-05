#!/usr/bin/env bash
# Boot TinyCorePure64 (graphical) with psi installed, exposed over VNC.
#
# The guest carries live psi credentials, so VNC is password-protected by
# default. The password lives in ./vncpasswd (generated on first run).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ISO="$HERE/downloads/TinyCorePure64-current.iso"
DISK="$HERE/disk.qcow2"

VNC_HOST="${VNC_HOST:-0.0.0.0}"
VNC_DISPLAY="${VNC_DISPLAY:-10}"         # :10 -> TCP 5910
MEM="${MEM:-4096}"
# TinyCorePure64 runs Xfbdev, which draws on the vesafb framebuffer rather than
# probing the card itself. The mode has to be set by the kernel's real-mode
# boot code via vga=, exactly as the ISO's isolinux.cfg does; without it there
# is no /dev/fb0 driver and Xfbdev exits at startup.
#   791 = 1024x768x16   794 = 1280x1024x16
VGA_MODE="${VGA_MODE:-794}"
MONITOR_SOCK="$HERE/monitor.sock"
CONSOLE_SOCK="$HERE/console.sock"
SERIAL_LOG="$HERE/serial.log"
PWFILE="$HERE/vncpasswd"

for f in "$HERE/vmlinuz64" "$HERE/psi-core64.gz" "$ISO" "$DISK"; do
	[ -e "$f" ] || { echo "missing: $f (run build.sh / provision-disk.sh)" >&2; exit 1; }
done

# QEMU's VNC auth truncates at 8 characters, so generate exactly 8.
if [ ! -f "$PWFILE" ]; then
	tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8 > "$PWFILE"
	chmod 0600 "$PWFILE"
	echo "generated VNC password in $PWFILE"
fi

rm -f "$MONITOR_SOCK" "$CONSOLE_SOCK"

echo "VNC   : $VNC_HOST:$((5900 + VNC_DISPLAY))  (display :$VNC_DISPLAY)"
echo "passwd: $(cat "$PWFILE")"

# cde       -> load the X/GUI extensions off the ISO
# tce/home  -> persist installed extensions and /home/tc on the data disk
#
# /opt is deliberately NOT persisted: it carries psi and bootlocal.sh, which
# must track the initrd. With opt=sda1 the first boot's copy wins forever and
# rebuilds silently stop taking effect.
#
# usb-tablet is an absolute pointing device. Without it the guest gets relative
# mouse deltas and the pointer drifts out of sync with the VNC client's cursor.
exec qemu-system-x86_64 \
	-name psi-tinycore \
	-m "$MEM" \
	-smp 4 \
	-kernel "$HERE/vmlinuz64" \
	-initrd "$HERE/psi-core64.gz" \
	-append "loglevel=3 cde tce=sda1 home=sda1 vga=$VGA_MODE console=ttyS0" \
	-drive file="$DISK",format=qcow2,if=ide,index=0,media=disk \
	-drive file="$ISO",if=ide,index=2,media=cdrom \
	-netdev user,id=net0 \
	-device e1000,netdev=net0 \
	-vga std \
	-device usb-ehci,id=usb \
	-device usb-tablet,bus=usb.0 \
	-parallel none \
	-object secret,id=vncsec,file="$PWFILE" \
	-vnc "$VNC_HOST:$VNC_DISPLAY,password-secret=vncsec" \
	-monitor "unix:$MONITOR_SOCK,server,nowait" \
	-serial "file:$SERIAL_LOG" \
	-serial "unix:$CONSOLE_SOCK,server,nowait" \
	"$@"
