#!/usr/bin/env bash
# One-shot: boot TinyCore headless, partition+format the data disk for
# TinyCore persistence (tce/home/opt), then power off.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="$HERE/disk.qcow2"
STAGE="$HERE/.provision"

[ -f "$HERE/vmlinuz64" ] || { echo "run build.sh first" >&2; exit 1; }
[ -f "$DISK" ] || { echo "missing $DISK; run build.sh first" >&2; exit 1; }

echo "==> staging provisioning overlay"
rm -rf "$STAGE"
mkdir -p "$STAGE/opt"

cat > "$STAGE/opt/bootlocal.sh" <<'EOF'
#!/bin/sh
exec >/dev/console 2>&1
echo "PROVISION: partitioning /dev/sda"
echo -e "o\nn\np\n1\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
sleep 2
# Re-read the table so /dev/sda1 appears.
for i in 1 2 3 4 5; do [ -b /dev/sda1 ] && break; sleep 1; done
echo "PROVISION: formatting /dev/sda1 as ext4"
mkfs.ext4 -F -L tcedata /dev/sda1
mkdir -p /mnt/sda1
mount /dev/sda1 /mnt/sda1
mkdir -p /mnt/sda1/tce/optional /mnt/sda1/home /mnt/sda1/opt
umount /mnt/sda1
echo "PROVISION: done"
sync
poweroff -f
EOF
chmod 0755 "$STAGE/opt/bootlocal.sh"

( cd "$STAGE" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$HERE/.provision.gz"
cat "$HERE/core64.gz" "$HERE/.provision.gz" > "$HERE/.provision-core.gz"

echo "==> booting provisioning VM (headless)"
timeout 180 qemu-system-x86_64 \
	-m 1024 \
	-kernel "$HERE/vmlinuz64" \
	-initrd "$HERE/.provision-core.gz" \
	-append "loglevel=3 console=ttyS0" \
	-drive file="$DISK",format=qcow2,if=ide \
	-nographic -no-reboot \
	-net none 2>&1 | tail -25

echo "==> provisioning finished"
